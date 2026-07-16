import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating floating panel that hosts the toast stack in the
/// TOP-RIGHT of the main screen, just below the menu bar (brief § toasts-tripletap).
///
/// Like `RecordingBarPanel` it never becomes key/main (so it can't steal focus from
/// the app being dictated into), floats above full-screen apps, and ignores mouse
/// events entirely (toasts are informational — the user should never have to click
/// through them). It resizes to fit the current toast stack and re-anchors to the
/// top-right each time the stack changes.
@MainActor
final class ToastPanel {
    private var panel: NSPanel?
    private let center: ToastCenter
    private var cancellables = Set<AnyCancellable>()

    /// Margin from the right edge and from the bottom of the menu bar.
    private static let edgeInset: CGFloat = 12
    private static let width: CGFloat = 320
    /// Generous max height; the hosting view shrinks to its content and is top-anchored.
    private static let maxHeight: CGFloat = 600

    init(center: ToastCenter) {
        self.center = center
    }

    /// Builds the panel once and starts observing the toast stack for visibility.
    func install() {
        makePanel()
        // Show/hide + reposition whenever the stack changes.
        center.$toasts
            .receive(on: RunLoop.main)
            .sink { [weak self] toasts in self?.sync(toasts) }
            .store(in: &cancellables)
        sync(center.toasts)
    }

    @discardableResult
    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let p = ToastNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.maxHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true          // purely informational — never intercept clicks
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.animationBehavior = .none

        let root = ToastStackView(center: center)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        panel = p
        return p
    }

    private func sync(_ toasts: [Toast]) {
        guard let panel else { return }
        if toasts.isEmpty {
            panel.orderOut(nil)
            return
        }
        reposition()
        // orderFrontRegardless keeps focus elsewhere (does not activate the app).
        panel.orderFrontRegardless()
    }

    /// Anchors the (fixed-width, max-height) panel to the top-right of the main screen's
    /// visible frame. The SwiftUI content is top-anchored, so stacking happens downward
    /// from just below the menu bar. Uses `visibleFrame` so the panel clears the menu bar
    /// / notch chrome.
    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = NSSize(width: Self.width, height: min(Self.maxHeight, vf.height))
        let originX = vf.maxX - size.width - Self.edgeInset
        // Top-align: NSWindow origin is bottom-left, so y = top - height.
        let originY = vf.maxY - size.height
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height),
                       display: true)
    }
}

/// Non-activating panel that never becomes key/main.
private final class ToastNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
