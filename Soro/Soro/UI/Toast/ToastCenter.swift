import Foundation
import Combine

/// A single transient status toast (brief § toasts-tripletap / §4, §5A delighters).
///
/// A toast either auto-dismisses after `duration` seconds (with a draining countdown
/// bar in the UI) or is *sticky* (`duration == nil`) — used for "Transcribing…", which
/// must stay until the pipeline finishes and explicitly replaces/dismisses it.
struct Toast: Identifiable, Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case info       // neutral status (e.g. "Transcribing…", mic name)
        case success    // brief positive flash (e.g. "Pasted")
        case failure    // error (e.g. "Failed to transcribe")
    }

    let id: UUID
    var message: String
    /// SF Symbol name for the leading icon.
    var systemImage: String
    var style: Style
    /// Auto-dismiss delay in seconds. `nil` → sticky (no countdown, no auto-expire).
    var duration: TimeInterval?

    /// Wall-clock (monotonic) time this toast was shown. Set by `ToastCenter` at enqueue.
    fileprivate(set) var shownAt: TimeInterval

    init(id: UUID = UUID(),
         message: String,
         systemImage: String,
         style: Style = .info,
         duration: TimeInterval? = 3.0,
         shownAt: TimeInterval = 0) {
        self.id = id
        self.message = message
        self.systemImage = systemImage
        self.style = style
        self.duration = duration
        self.shownAt = shownAt
    }

    /// Fraction of the countdown remaining (1 → just shown, 0 → expired) at `now`.
    /// Always `1` for sticky toasts (they never drain).
    func remainingFraction(at now: TimeInterval) -> Double {
        guard let duration, duration > 0 else { return 1 }
        let elapsed = now - shownAt
        return min(1, max(0, 1 - elapsed / duration))
    }

    /// Whether this toast's countdown has fully elapsed by `now`. Sticky toasts never expire.
    func hasExpired(at now: TimeInterval) -> Bool {
        guard let duration, duration > 0 else { return false }
        return now - shownAt >= duration
    }
}

/// Central store + expiry engine for transient toasts. The enqueue/expire logic is pure
/// and clock-injectable so it is unit-testable without timers or a window server; the
/// SwiftUI-facing `@Published toasts` array drives `ToastPanel`.
///
/// Newest toasts are appended to the end; the panel stacks them top-down. Multiple toasts
/// coexist (stacked). A short cap keeps the stack from growing unbounded if the pipeline
/// emits faster than toasts expire.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var toasts: [Toast] = []

    /// Maximum simultaneously visible toasts; oldest auto-dismissible one is dropped past this.
    private let maxVisible: Int
    /// Monotonic clock. Injectable for tests; defaults to process uptime.
    private let now: () -> TimeInterval

    private var timer: Timer?

    /// `nonisolated` so it can serve as a default-argument value in other MainActor initializers
    /// (e.g. `DictationCoordinator`), which are evaluated in a synchronous context. Only stores
    /// plain values; no main-actor state is touched here.
    nonisolated init(maxVisible: Int = 4,
                     now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maxVisible = maxVisible
        self.now = now
    }

    // MARK: - Pure core (unit-tested)

    /// Enqueue a toast, stamping its show time from the injected clock. Returns its id so a
    /// caller can later dismiss/replace it (e.g. the sticky "Transcribing…" toast).
    @discardableResult
    func show(_ toast: Toast) -> UUID {
        var t = toast
        t.shownAt = now()
        toasts.append(t)
        // Drop the oldest *auto-dismissible* toast if we exceed the cap. Sticky toasts
        // (duration == nil) are never auto-dropped — the pipeline owns their lifetime.
        if toasts.count > maxVisible {
            if let idx = toasts.firstIndex(where: { $0.duration != nil }) {
                toasts.remove(at: idx)
            } else {
                toasts.removeFirst()
            }
        }
        scheduleTick()
        return t.id
    }

    /// Convenience enqueue.
    @discardableResult
    func show(_ message: String,
              systemImage: String,
              style: Toast.Style = .info,
              duration: TimeInterval? = 3.0) -> UUID {
        show(Toast(message: message, systemImage: systemImage, style: style, duration: duration))
    }

    /// Remove a specific toast (used to clear the sticky "Transcribing…" toast when the
    /// pipeline finishes). No-op if it already expired.
    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        scheduleTick()
    }

    /// Replace a toast in place (keeps its stack position) — e.g. "Transcribing…" → "Pasted".
    /// Falls back to a plain `show` if the id is gone. Returns the new toast's id.
    @discardableResult
    func replace(_ id: UUID, with toast: Toast) -> UUID {
        guard let idx = toasts.firstIndex(where: { $0.id == id }) else { return show(toast) }
        var t = toast
        t.shownAt = now()
        toasts[idx] = t
        scheduleTick()
        return t.id
    }

    func dismissAll() {
        toasts.removeAll()
        stopTimer()
    }

    /// Drop every toast whose countdown has elapsed by `at`. Pure: no timers. Returns whether
    /// anything changed (so callers/tests can assert). Sticky toasts are retained.
    @discardableResult
    func expire(at time: TimeInterval) -> Bool {
        let before = toasts.count
        toasts.removeAll { $0.hasExpired(at: time) }
        return toasts.count != before
    }

    /// The soonest future instant at which some toast expires, or `nil` if none will
    /// (all sticky / empty). Used to schedule the next tick.
    func nextExpiry() -> TimeInterval? {
        toasts.compactMap { t -> TimeInterval? in
            guard let d = t.duration, d > 0 else { return nil }
            return t.shownAt + d
        }.min()
    }

    // MARK: - Timer plumbing (thin; correctness lives in the pure core)

    private func scheduleTick() {
        stopTimer()
        guard let expiry = nextExpiry() else { return }
        let delay = max(0.02, expiry - now())
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        _ = expire(at: now())
        // Reschedule for the next-soonest expiry (multiple toasts drain independently).
        scheduleTick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Semantic helpers used by the pipeline / AppState

extension ToastCenter {
    /// Sticky "Transcribing…" toast — no auto-dismiss; caller keeps the returned id and
    /// dismisses/replaces it when the pipeline resolves.
    @discardableResult
    func showTranscribing() -> UUID {
        show("Transcribing…", systemImage: "waveform", style: .info, duration: nil)
    }

    @discardableResult
    func showPasted() -> UUID {
        show("Pasted", systemImage: "checkmark.circle.fill", style: .success, duration: 1.6)
    }

    @discardableResult
    func showTranscribeFailed() -> UUID {
        show("Failed to transcribe", systemImage: "exclamationmark.triangle.fill",
             style: .failure, duration: 3.0)
    }

    @discardableResult
    func showMicrophone(_ name: String) -> UUID {
        let label = name.isEmpty ? "Default microphone" : name
        return show(label, systemImage: "mic.fill", style: .info, duration: 2.4)
    }
}
