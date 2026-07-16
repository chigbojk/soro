import AppKit
import Combine

/// Captures the frontmost application's icon at record start so the recording
/// pill can show which app you're dictating into (brief §4a redesign — left
/// slot). When no app / icon can be resolved, `icon` stays nil and the view
/// renders a mic SF Symbol instead (see `RecordingBarModel.leftIcon`).
///
/// Lives in `UI/Bar/` and owns no stores. The panel calls `captureFrontmost()`
/// on the transition into a recording state and `clear()` when recording ends.
@MainActor
final class LeftIconProvider: ObservableObject {
    /// The captured frontmost-app icon, or nil to signal the mic fallback.
    @Published private(set) var icon: NSImage?

    /// Overridable resolver so tests / previews can inject a deterministic icon
    /// without a live `NSWorkspace`.
    private let resolveFrontmostIcon: () -> NSImage?

    init(resolveFrontmostIcon: @escaping () -> NSImage? = {
        NSWorkspace.shared.frontmostApplication?.icon
    }) {
        self.resolveFrontmostIcon = resolveFrontmostIcon
    }

    /// Snapshots the current frontmost app's icon. Call at record *start* so the
    /// icon reflects the dictation target even if focus later changes.
    func captureFrontmost() {
        icon = resolveFrontmostIcon()
    }

    /// Drops the captured icon (back to mic fallback) once recording is over.
    func clear() {
        icon = nil
    }

    /// Whether a real app icon is currently available.
    var hasIcon: Bool { icon != nil }
}
