import CoreGraphics
import Foundation

/// Pure presentation logic for the recording bar (brief §4a), kept free of AppKit
/// so it can be unit-tested without a window server. `RecordingBarView` and
/// `RecordingBarPanel` derive everything they render from these helpers.
enum RecordingBarModel {

    // MARK: State → visibility

    /// What the bar is showing at a glance. The panel maps this to show/hide.
    enum Phase: Equatable {
        case hidden          // idle → nothing on screen (default hidden-when-idle)
        case dormant         // idle → tiny click-to-start pill (hideBarWhenIdle == false)
        case recording(locked: Bool)
        case transcribing
        case doneFlash       // brief success flash before hiding
    }

    /// Maps the coordinator's `DictationState` + user prefs to a render phase.
    ///
    /// - `notchEnabled`: master switch (`enableNotchView`). When false the bar is
    ///   always hidden.
    /// - `hideBar`: when true the bar never shows even while recording (headless
    ///   users who rely purely on sound cues).
    /// - `hideBarWhenIdle`: when true the idle state is fully hidden; when false a
    ///   dormant pill is shown so the bar can be clicked to start.
    static func phase(for state: DictationState,
                      notchEnabled: Bool,
                      hideBar: Bool,
                      hideBarWhenIdle: Bool) -> Phase {
        guard notchEnabled, !hideBar else { return .hidden }
        switch state {
        case .idle:
            return hideBarWhenIdle ? .hidden : .dormant
        case .recording(let locked):
            return .recording(locked: locked)
        case .transcribing, .inserting:
            // De-duped: the top-right toast now owns all post-recording status
            // ("Transcribing"/"Failed"/"Pasted"). The island retreats the instant
            // recording stops so the two surfaces never show the same thing.
            return .hidden
        case .done:
            // Same rationale — the toast shows the success/paste result.
            return .hidden
        case .error:
            // Errors surface elsewhere (toast / menu); the bar just retreats.
            return .hidden
        }
    }

    /// Whether the panel window should be ordered in for a given phase.
    static func isVisible(_ phase: Phase) -> Bool {
        switch phase {
        case .hidden:               return false
        case .dormant,
             .recording,
             .transcribing,
             .doneFlash:            return true
        }
    }

    /// Whether the live waveform + timer chrome should be shown.
    static func isRecordingPhase(_ phase: Phase) -> Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Whether the lock glyph should be shown.
    static func showsLock(_ phase: Phase) -> Bool {
        if case .recording(let locked) = phase { return locked }
        return false
    }

    // MARK: Frame persistence (string codec)

    /// Serializes a frame to a stable, human-readable string so the panel can
    /// persist its position through the injected `setFrame` closure without
    /// importing `PreferencesStore`. Format: "x,y,width,height".
    static func encodeFrame(_ rect: CGRect) -> String {
        "\(rect.origin.x),\(rect.origin.y),\(rect.size.width),\(rect.size.height)"
    }

    /// Parses a frame string produced by `encodeFrame`. Returns nil for any
    /// malformed / empty input so callers fall back to the default position
    /// instead of crashing or placing the bar off-screen.
    static func decodeFrame(_ string: String?) -> CGRect? {
        guard let string, !string.isEmpty else { return nil }
        let parts = string.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let x = values[0], let y = values[1],
              let w = values[2], let h = values[3] else { return nil }
        guard w.isFinite, h.isFinite, x.isFinite, y.isFinite, w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Notch geometry

    /// Fallback physical-notch width (points) used on notched Macs when the exact
    /// aux-area rects can't be read from the screen. Measured ~200pt on 16" MBP.
    static let fallbackNotchWidth: CGFloat = 200

    /// Width of ONE flanking content zone (left or right of the notch). Sized so
    /// the right zone's waveform + elapsed timer + cancel button fit comfortably.
    static let sideZoneWidth: CGFloat = 168

    /// Total pill height. The top edge sits flush against the screen's physical
    /// top, so the pill spans the menu-bar/notch band and extends just below it —
    /// content on the flanks then clears the notch's bottom edge.
    static let pillHeight: CGFloat = 44

    /// Corner radius for the pill's rounded BOTTOM corners (top corners are square
    /// so they stay flush with the screen's top edge, letting the black pill merge
    /// with the physical notch).
    static let bottomCornerRadius: CGFloat = 18

    /// Computes the physical notch width for the current display.
    ///
    /// Prefers the exact left/right aux-area rects (their inner edges bound the
    /// notch); falls back to `fallbackNotchWidth` when only a notch *hint*
    /// (`safeAreaTopInset > 0`) is present, and to `0` (no gap → plain centered
    /// pill) on non-notched Macs.
    ///
    /// - Parameters:
    ///   - fullFrame: the screen's full `frame`.
    ///   - auxLeftMaxX: `auxiliaryTopLeftAreaOfScreen?.maxX` (notch left edge), or nil.
    ///   - auxRightMinX: `auxiliaryTopRightAreaOfScreen?.minX` (notch right edge), or nil.
    ///   - safeAreaTopInset: `safeAreaInsets.top` (>0 signals a notch).
    static func notchWidth(fullFrame: CGRect,
                           auxLeftMaxX: CGFloat?,
                           auxRightMinX: CGFloat?,
                           safeAreaTopInset: CGFloat = 0) -> CGFloat {
        if let l = auxLeftMaxX, let r = auxRightMinX, r > l,
           l > fullFrame.minX, r < fullFrame.maxX {
            return r - l
        }
        // Only the left edge known: mirror it across the display center.
        if let l = auxLeftMaxX, l > fullFrame.minX, l < fullFrame.midX {
            return (fullFrame.midX - l) * 2
        }
        // A notch is present (top inset) but exact edges are unavailable.
        if safeAreaTopInset > 0 { return fallbackNotchWidth }
        return 0
    }

    /// Total pill width for a given notch gap: two flanking zones plus the gap the
    /// notch sits in. On non-notched Macs (`notchGap == 0`) this collapses to a
    /// plain centered pill of `2 * sideZoneWidth`.
    static func pillWidth(notchGap: CGFloat, sideZone: CGFloat = sideZoneWidth) -> CGFloat {
        max(0, notchGap) + 2 * sideZone
    }

    /// Back-compat default width (used by the plain view initializer / previews
    /// and the panel's default size before it derives the live notch geometry).
    static var pillWidth: CGFloat { pillWidth(notchGap: fallbackNotchWidth) }

    /// Computes the horizontal center (in AppKit screen coordinates) of the
    /// physical notch, so the pill can sit symmetrically beneath it.
    ///
    /// On notched Macs `NSScreen.auxiliaryTopLeftAreaOfScreen` returns the usable
    /// menu-bar region to the *left* of the notch: its `maxX` is the notch's left
    /// edge. The notch's right edge mirrors it across the screen center, so the
    /// notch center is simply the screen's horizontal midpoint. On Macs with no
    /// notch (`auxLeft == nil`) we also fall back to the screen midpoint. We derive
    /// the value defensively from whichever inputs are present.
    ///
    /// - Parameters:
    ///   - fullFrame: the screen's full `frame` (not `visibleFrame`).
    ///   - auxLeftMaxX: `auxiliaryTopLeftAreaOfScreen?.maxX` if available, else nil.
    ///   - safeAreaLeftInset: `safeAreaInsets.left` if available (0 on non-notched).
    static func notchCenterX(fullFrame: CGRect,
                             auxLeftMaxX: CGFloat?,
                             safeAreaLeftInset: CGFloat = 0) -> CGFloat {
        // The physical notch is centered on the display. Both the aux-area maxX
        // (left edge of notch) and the left safe-area inset describe the same
        // symmetric cutout, so the notch center collapses to the screen midpoint.
        // We still consult the inputs so that on unusual layouts (e.g. external
        // display reporting an offset aux area) we honor the reported left edge.
        if let auxLeftMaxX, auxLeftMaxX > fullFrame.minX, auxLeftMaxX < fullFrame.maxX {
            let leftEdge = auxLeftMaxX
            // Right edge mirrors the left edge across the display center.
            let rightEdge = fullFrame.maxX - (leftEdge - fullFrame.minX)
            return (leftEdge + rightEdge) / 2
        }
        // No aux area but a left safe-area inset still hints the cutout width.
        if safeAreaLeftInset > 0 {
            return fullFrame.midX
        }
        return fullFrame.midX
    }

    // MARK: Default placement

    /// TOP-FLUSH origin for the Dynamic-Island pill: its TOP edge sits exactly at
    /// the screen's physical top (`fullFrame.maxY`), horizontally centered on the
    /// notch. Pass the FULL screen `frame` (NOT `visibleFrame`) so the pill
    /// occupies the menu-bar/notch band and its black body merges with the
    /// physical notch.
    ///
    /// - Parameters:
    ///   - fullFrame: the screen's full `frame`.
    ///   - size: the pill size.
    ///   - centerX: notch center X (AppKit coords). Defaults to `fullFrame.midX`.
    ///   - topInset: gap below the physical top edge; `0` = perfectly flush.
    static func topFlushOrigin(in fullFrame: CGRect,
                               size: CGSize,
                               centerX: CGFloat? = nil,
                               topInset: CGFloat = 0) -> CGPoint {
        let cx = centerX ?? fullFrame.midX
        let x = cx - size.width / 2
        // AppKit screen coords: y grows upward, so the top edge is maxY.
        let y = fullFrame.maxY - size.height - topInset
        return CGPoint(x: x, y: y)
    }

    /// Legacy centered-near-top origin (kept for callers/tests that positioned the
    /// bar *below* the menu bar). Prefer `topFlushOrigin` for the island look.
    static func defaultOrigin(in screenFrame: CGRect,
                              size: CGSize,
                              topInset: CGFloat = 8,
                              centerX: CGFloat? = nil) -> CGPoint {
        topFlushOrigin(in: screenFrame, size: size, centerX: centerX, topInset: topInset)
    }

    /// Whether a persisted frame should be adopted on launch. Rejects it when:
    /// - the user never actually moved the bar (`userMoved == false`) — we always
    ///   re-derive the top-flush notch position instead; or
    /// - its size doesn't match the current pill size (a stale frame from an older
    ///   build, e.g. the 120×38 pill that stranded the bar). Only the *position*
    ///   is worth restoring, and only when the size still matches.
    ///
    /// `tolerance` absorbs sub-point rounding from the persistence codec.
    static func shouldAdoptPersistedFrame(_ persisted: CGRect,
                                          currentSize: CGSize,
                                          userMoved: Bool,
                                          tolerance: CGFloat = 0.5) -> Bool {
        guard userMoved else { return false }
        return abs(persisted.width - currentSize.width) <= tolerance
            && abs(persisted.height - currentSize.height) <= tolerance
    }

    /// Clamps a proposed frame so at least `minVisible` points stay on `screenFrame`,
    /// preventing a persisted position from stranding the bar off-screen after a
    /// display change.
    static func clamp(_ frame: CGRect,
                      to screenFrame: CGRect,
                      minVisible: CGFloat = 40) -> CGRect {
        var origin = frame.origin
        let maxX = screenFrame.maxX - minVisible
        let minX = screenFrame.minX - (frame.width - minVisible)
        let maxY = screenFrame.maxY - minVisible
        let minY = screenFrame.minY - (frame.height - minVisible)
        origin.x = min(max(origin.x, minX), maxX)
        origin.y = min(max(origin.y, minY), maxY)
        return CGRect(origin: origin, size: frame.size)
    }

    // MARK: Timer formatting

    /// mm:ss elapsed label for the recording chrome.
    static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Left-side icon

    /// What the pill's left slot should display: the frontmost app's icon captured
    /// at record start, or a mic SF Symbol fallback when no app icon is resolvable.
    enum LeftIcon: Equatable {
        case appIcon          // render the captured NSImage
        case micFallback      // render "mic.fill"
    }

    /// Decides the left slot. `hasCapturedIcon` is whether an `NSImage` was
    /// resolved from `NSWorkspace.frontmostApplication?.icon` at record start.
    /// Falls back to the mic symbol whenever no icon is available.
    static func leftIcon(hasCapturedIcon: Bool) -> LeftIcon {
        hasCapturedIcon ? .appIcon : .micFallback
    }

    // MARK: Waveform sampling

    /// Normalizes a raw 0…1 mic level into a bar height fraction with a small
    /// noise floor so idle mic hiss doesn't jitter the bars.
    static func barHeightFraction(forLevel level: Float, floor: Float = 0.06) -> CGFloat {
        let clamped = min(max(level, 0), 1)
        guard clamped > floor else { return CGFloat(floor) }
        // Mild expansion so quiet speech is still visible.
        let shaped = powf(clamped, 0.7)
        return CGFloat(min(max(shaped, floor), 1))
    }
}
