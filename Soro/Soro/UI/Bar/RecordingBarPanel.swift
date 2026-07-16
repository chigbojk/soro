import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating floating panel that hosts `RecordingBarView` under
/// the notch (brief §4a). It never becomes key/main so it can't steal focus from
/// the app the user is dictating into, floats above full-screen apps, is
/// draggable to reposition, and persists its frame through injected closures so
/// this file never imports `PreferencesStore`.
@MainActor
final class RecordingBarPanel {
    private var panel: BarPanel?
    private let coordinator: DictationCoordinator

    /// Live mic levels (~30 Hz) forwarded to the waveform.
    private let levelStream: AsyncStream<Float>
    /// Frame persistence bridges (owner decides where the string lives).
    private let getFrame: () -> String?
    private let setFrame: (String) -> Void
    /// Notified the first time the user drags the bar (Willow's `barEverMoved`).
    private let onFirstMove: () -> Void
    /// Whether the user has EVER moved the bar (persisted across launches). Gates
    /// whether a saved frame is restored vs. re-deriving the top-flush position.
    private let barEverMoved: () -> Bool
    /// Preference inputs for render-phase decisions.
    private let notchEnabled: () -> Bool
    private let hideBar: () -> Bool
    private let hideBarWhenIdle: () -> Bool

    private var cancellables = Set<AnyCancellable>()
    private var hasMoved = false
    private var hasReportedMove = false

    /// Captures the frontmost-app icon at record start for the pill's left slot.
    private let leftIcon = LeftIconProvider()
    /// Tracks whether we're currently in a recording state (to fire icon capture
    /// exactly on the idle→recording edge).
    private var wasRecording = false

    /// Cached notch gap for the current display (0 on non-notched Macs), computed
    /// when positioning. Drives the SwiftUI layout so the zones flank the notch.
    private var currentNotchGap: CGFloat = RecordingBarModel.fallbackNotchWidth

    /// Live pill size for the current display's notch geometry.
    private var pillSize: CGSize {
        CGSize(width: RecordingBarModel.pillWidth(notchGap: currentNotchGap),
               height: RecordingBarModel.pillHeight)
    }

    /// Fallback size before a screen is resolved (16" MBP defaults).
    private static let defaultSize = CGSize(width: RecordingBarModel.pillWidth,
                                            height: RecordingBarModel.pillHeight)

    init(coordinator: DictationCoordinator,
         levelStream: AsyncStream<Float>? = nil,
         getFrame: @escaping () -> String? = { nil },
         setFrame: @escaping (String) -> Void = { _ in },
         onFirstMove: @escaping () -> Void = {},
         barEverMoved: @escaping () -> Bool = { false },
         notchEnabled: @escaping () -> Bool = { true },
         hideBar: @escaping () -> Bool = { false },
         hideBarWhenIdle: @escaping () -> Bool = { true }) {
        self.coordinator = coordinator
        self.levelStream = levelStream ?? AsyncStream { $0.finish() }
        self.getFrame = getFrame
        self.setFrame = setFrame
        self.onFirstMove = onFirstMove
        self.barEverMoved = barEverMoved
        self.notchEnabled = notchEnabled
        self.hideBar = hideBar
        self.hideBarWhenIdle = hideBarWhenIdle
    }

    // MARK: Lifecycle

    /// Builds (once) and returns the panel, wiring visibility to coordinator state.
    @discardableResult
    func makePanel() -> NSPanel {
        if let panel { return panel }
        // Resolve the notch geometry up front so the SwiftUI zones flank it and the
        // panel is sized to match before first display.
        if let screen = NSScreen.main {
            currentNotchGap = Self.notchGap(of: screen)
        }
        let p = BarPanel(
            contentRect: NSRect(origin: .zero, size: pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        p.isFloatingPanel = true
        // ABOVE the menu bar so the island's top edge merges with the notch band
        // instead of hiding behind the menu bar. mainMenu+1 clears menu-bar items.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // The pill ignores mouse events on its transparent regions but its controls
        // (the X button) still receive clicks — hit-testing falls through clear px.
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.animationBehavior = .none

        let root = RecordingBarView(
            coordinator: coordinator,
            leftIcon: leftIcon,
            levelStream: levelStream,
            notchEnabled: notchEnabled(),
            hideBar: hideBar(),
            hideBarWhenIdle: hideBarWhenIdle(),
            notchGap: currentNotchGap,
            sideZone: RecordingBarModel.sideZoneWidth,
            onCancel: { [coordinator] in coordinator.cancelRecording() })
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        p.onMoved = { [weak self] in self?.panelDidMove() }
        panel = p

        applyPersistedFrame()
        observeState()
        return p
    }

    /// Ensures the panel is built and its visibility reflects the current state.
    func install() {
        makePanel()
        syncVisibility(coordinator.state)
    }

    // MARK: Visibility

    private func observeState() {
        coordinator.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.syncVisibility(state) }
            .store(in: &cancellables)
    }

    private func syncVisibility(_ state: DictationState) {
        guard let panel else { return }
        // Capture the frontmost app's icon on the idle→recording edge so the pill
        // shows the dictation target even if focus later shifts; clear it once the
        // recording session fully ends (back to idle/hidden).
        let isRecording: Bool = { if case .recording = state { return true } else { return false } }()
        if isRecording && !wasRecording {
            leftIcon.captureFrontmost()
        } else if case .idle = state {
            leftIcon.clear()
        }
        wasRecording = isRecording

        let phase = RecordingBarModel.phase(
            for: state,
            notchEnabled: notchEnabled(),
            hideBar: hideBar(),
            hideBarWhenIdle: hideBarWhenIdle())
        if RecordingBarModel.isVisible(phase) {
            if !panel.isVisible { positionIfNeeded() }
            // orderFrontRegardless avoids activating the app (keeps focus elsewhere).
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: Frame persistence + placement

    private func applyPersistedFrame() {
        guard let panel else { return }
        // Only adopt a persisted frame when the user actually moved the bar AND the
        // saved size still matches the current pill (rejects stale frames from old
        // builds — e.g. the 120×38 pill that stranded the bar). Otherwise always
        // re-derive the top-flush notch position.
        if let rect = RecordingBarModel.decodeFrame(getFrame()),
           RecordingBarModel.shouldAdoptPersistedFrame(rect,
                                                        currentSize: pillSize,
                                                        userMoved: barEverMoved()),
           let screen = screenFor(rect) {
            panel.setFrame(RecordingBarModel.clamp(rect, to: screen.visibleFrame), display: false)
            hasMoved = true
        } else {
            positionTopFlush()
        }
    }

    /// Pins the island top-flush: its TOP edge at the screen's physical top edge
    /// (`frame.maxY`), centered on the notch, using the FULL frame so the black
    /// body merges with the physical notch. Only when the user hasn't moved it.
    private func positionTopFlush() {
        guard let panel, let screen = NSScreen.main else { return }
        currentNotchGap = Self.notchGap(of: screen)
        let size = pillSize
        let centerX = Self.notchCenterX(of: screen)
        let origin = RecordingBarModel.topFlushOrigin(in: screen.frame,
                                                      size: size,
                                                      centerX: centerX,
                                                      topInset: 0)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
    }

    /// Resolves the physical notch's horizontal center for `screen` using the
    /// AppKit APIs when present, delegating the arithmetic to the pure
    /// `RecordingBarModel.notchCenterX` so it stays unit-testable.
    private static func notchCenterX(of screen: NSScreen) -> CGFloat {
        var auxLeftMaxX: CGFloat?
        var safeLeft: CGFloat = 0
        if #available(macOS 12.0, *) {
            // `auxiliaryTopLeftArea` is nil on displays without a notch; a present
            // rect's maxX is the notch's left edge.
            if let aux = screen.auxiliaryTopLeftArea, aux.width > 0 {
                auxLeftMaxX = aux.maxX
            }
            safeLeft = screen.safeAreaInsets.left
        }
        return RecordingBarModel.notchCenterX(fullFrame: screen.frame,
                                              auxLeftMaxX: auxLeftMaxX,
                                              safeAreaLeftInset: safeLeft)
    }

    /// Resolves the physical notch width for `screen` using the exact aux-area
    /// left/right rects when present (KVC on older SDKs), delegating the math to
    /// `RecordingBarModel.notchWidth` so it stays unit-testable.
    private static func notchGap(of screen: NSScreen) -> CGFloat {
        var auxLeftMaxX: CGFloat?
        var auxRightMinX: CGFloat?
        var safeTop: CGFloat = 0
        if #available(macOS 12.0, *) {
            if let aux = screen.auxiliaryTopLeftArea, aux.width > 0 {
                auxLeftMaxX = aux.maxX
            }
            if let aux = screen.auxiliaryTopRightArea, aux.width > 0 {
                auxRightMinX = aux.minX
            }
            safeTop = screen.safeAreaInsets.top
        }
        return RecordingBarModel.notchWidth(fullFrame: screen.frame,
                                            auxLeftMaxX: auxLeftMaxX,
                                            auxRightMinX: auxRightMinX,
                                            safeAreaTopInset: safeTop)
    }

    private func positionIfNeeded() {
        // If the user never moved it, re-pin top-flush each time it appears so it
        // tracks the active display and current notch geometry.
        if !hasMoved { positionTopFlush() }
    }

    private func panelDidMove() {
        guard let panel else { return }
        hasMoved = true
        setFrame(RecordingBarModel.encodeFrame(panel.frame))
        if !hasReportedMove {
            hasReportedMove = true
            onFirstMove()
        }
    }

    private func screenFor(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    }
}

/// Non-activating panel that never becomes key/main and reports background drags.
private final class BarPanel: NSPanel {
    var onMoved: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Fires after a window-background drag settles.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMoved?()
    }
}
