import Foundation

// MARK: - Inputs

/// A raw, CGEvent-free key event fed into the recognizer. `HotkeyManager` translates
/// live `CGEvent`s into these; tests synthesize them directly. Timestamps are in
/// seconds (monotonic wall-clock, e.g. `CGEvent.timestamp` converted to seconds, or
/// `ProcessInfo.systemUptime`). The recognizer only ever *compares* timestamps, so any
/// monotonic clock works as long as it is used consistently.
enum HotkeyEventKind: Sendable, Equatable {
    case keyDown
    case keyUp
    case flagsChanged   // modifier-only triggers arrive as flagsChanged
}

struct HotkeyEvent: Sendable, Equatable {
    let kind: HotkeyEventKind
    /// Virtual keyCode of the key that changed.
    let keyCode: UInt16
    /// Modifier flags currently active (Cocoa `NSEvent.ModifierFlags.rawValue`-style
    /// bitmask). Used to detect the paste-last combo (Left Cmd + key). For a
    /// modifier-only trigger event this is the flag state *after* the change.
    let modifiers: UInt64
    /// True when the changed key is *pressed* (relevant for `flagsChanged`, where there
    /// is no keyDown/keyUp distinction — the manager derives press/release from whether
    /// the trigger's modifier bit is now set). For `keyDown` this is `true`, for `keyUp`
    /// `false`; callers may override for flagsChanged.
    let isDown: Bool
    /// Monotonic timestamp in seconds.
    let timestamp: TimeInterval

    init(kind: HotkeyEventKind,
         keyCode: UInt16,
         modifiers: UInt64 = 0,
         isDown: Bool,
         timestamp: TimeInterval) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isDown = isDown
        self.timestamp = timestamp
    }
}

// MARK: - Config

/// Timing + binding configuration for the recognizer. Defaults follow brief §2 /
/// Appendix C (double-tap window ~250–300 ms).
struct HotkeyRecognizerConfig: Sendable, Equatable {
    /// The primary (modifier-only) trigger. Its `keyCode` is what the recognizer keys on.
    var trigger: HotkeyData
    /// Optional paste-last-transcript combo (Left Cmd + key). `nil` disables it.
    var pasteHotkey: HotkeyData?
    /// Max gap between the *first key-up* and the *second key-down* for a double-tap to
    /// register as a lock. ~0.28 s (Appendix C: 250–300 ms). A slow hold whose release
    /// lands after this window can never become a lock.
    var doubleTapWindow: TimeInterval
    /// Virtual keyCode for Escape (cancels while recording).
    var escapeKeyCode: UInt16

    init(trigger: HotkeyData = .leftOption,
         pasteHotkey: HotkeyData? = nil,
         doubleTapWindow: TimeInterval = 0.28,
         escapeKeyCode: UInt16 = 53) {
        self.trigger = trigger
        self.pasteHotkey = pasteHotkey
        self.doubleTapWindow = doubleTapWindow
        self.escapeKeyCode = escapeKeyCode
    }
}

// MARK: - Left Command flag

/// Cocoa flag masks we care about. Left Cmd shares the generic `.command` device-independent
/// bit (0x100000); the device-dependent left-command bit is `0x8`. We accept either so the
/// paste combo works regardless of whether the source reports device flags.
private enum ModifierMask {
    static let command: UInt64 = 0x0010_0000        // NSEvent.ModifierFlags.command
    static let leftCommandDevice: UInt64 = 0x0000_0008
}

// MARK: - Recognizer

/// Pure, deterministic state machine that turns raw key events into `HotkeyGesture`s.
/// NO CoreGraphics / CGEvent imports — it is unit-testable in isolation and is the piece
/// under adversarial review.
///
/// ## Timing model (the whole product — read carefully)
///
/// The trigger is a *modifier-only* key (default Left Option). We must satisfy two goals
/// that pull in opposite directions:
///   1. A single **press-and-hold** must start recording **promptly** (push-to-talk), with
///      no perceptible delay — you can't make the user wait out the double-tap window before
///      audio starts.
///   2. A **double-tap** must **lock** recording on, and must NOT leave a spurious PTT
///      session behind.
///
/// Resolution — *record-immediately, upgrade-on-second-tap*:
///   - On the **first trigger down** while idle, we emit `.pushToTalkBegan` right away and
///     enter `.ptt`. Recording is live from the first press.
///   - If the user simply **holds**, nothing else happens until they **release**, which emits
///     `.pushToTalkEnded`. A long/slow hold therefore can never be mistaken for a double-tap
///     (goal 1, and Appendix C "slow hold never registers as double-tap").
///   - If the user **releases quickly** (before we've seen a second tap), we move to
///     `.pendingDoubleTap`, remembering the release time, but we have ALREADY told the
///     coordinator recording began. We do NOT emit `.pushToTalkEnded` yet — we wait out the
///     double-tap window:
///       * If a **second down** arrives within `doubleTapWindow` of the release → it's a
///         double-tap → emit `.lockToggledOn`, enter `.locked`. The already-running recording
///         is simply *kept* and locked; no stop/restart, no dropped audio.
///       * If the window **expires** with no second down → the short press was a genuine, if
///         brief, PTT. Emit `.pushToTalkEnded` (record-and-stop). The input is never swallowed
///         — a quick tap yields a real short dictation, not a no-op (goal 2's failure mode
///         avoided; brief §2 "release-before-window still yields a valid short PTT").
///   - The window is only ever measured from a *release*, so a hold that outlasts the window
///     while still down commits to PTT the instant it is released — it can't retroactively
///     become a lock.
///
/// Locked semantics (brief §2):
///   - While `.locked`, **any trigger press** (tap or hold — we act on down) stops: emit
///     `.lockToggledOff` and `.pushToTalkEnded`, return to idle. Holding while locked is
///     treated as "stop" (Appendix C).
///   - Escape while recording (PTT, pending, or locked) → `.cancel`, discard, return to idle.
///
/// The recognizer is intentionally *clock-free at rest*: `.pendingDoubleTap` needs an external
/// nudge to expire. Callers must invoke `tick(now:)` (a timer fires it) OR the arrival of the
/// next event carries a timestamp we use to lazily expire the pending window. Both paths are
/// covered so a caller that forgets the timer still resolves correctly on the next keypress.
final class HotkeyGestureRecognizer {

    // MARK: State

    private enum State: Equatable {
        /// Not recording.
        case idle
        /// Recording, trigger currently held (push-to-talk in progress).
        case ptt
        /// Recording began, trigger released; within the window a 2nd tap upgrades to lock.
        /// `releaseTime` is when the trigger came up.
        case pendingDoubleTap(releaseTime: TimeInterval)
        /// Recording locked on (hands-free), trigger of the 2nd (lock) tap still held.
        case locked
        /// Locked on, but the 2nd (lock) tap has been released and we are within the
        /// window watching for a *3rd* tap — a triple-tap that fires `.showMicrophone`
        /// without disturbing the locked recording. If the window expires with no 3rd
        /// down we simply stay `.locked` (a normal double-tap-lock). `lockReleaseTime`
        /// is when the lock tap came up. Recording is always live in this state.
        case lockedPendingTriple(lockReleaseTime: TimeInterval)
    }

    private var state: State = .idle
    private var config: HotkeyRecognizerConfig

    /// Emits resolved gestures. Set by the manager; tests capture into an array.
    var onGesture: (HotkeyGesture) -> Void

    init(config: HotkeyRecognizerConfig = HotkeyRecognizerConfig(),
         onGesture: @escaping (HotkeyGesture) -> Void = { _ in }) {
        self.config = config
        self.onGesture = onGesture
    }

    /// Whether a recording is currently active from the recognizer's point of view. Mirrors
    /// (and is authoritative for) Esc + lock semantics. The coordinator may also set its own
    /// flag, but the recognizer tracks this internally so it never depends on external state.
    var isRecordingActive: Bool {
        switch state {
        case .idle: return false
        case .ptt, .pendingDoubleTap, .locked, .lockedPendingTriple: return true
        }
    }

    /// True while a double-tap decision is still pending (recording live, trigger released,
    /// window not yet expired). Exposed for the manager's timer scheduling and for tests.
    var isPendingDoubleTap: Bool {
        if case .pendingDoubleTap = state { return true }
        return false
    }

    /// The absolute time at which a pending double-tap window expires, or `nil` if not pending.
    /// The manager schedules a timer for this instant.
    var pendingExpiry: TimeInterval? {
        switch state {
        case let .pendingDoubleTap(releaseTime):
            return releaseTime + config.doubleTapWindow
        case let .lockedPendingTriple(lockReleaseTime):
            return lockReleaseTime + config.doubleTapWindow
        case .idle, .ptt, .locked:
            return nil
        }
    }

    func updateConfig(_ newConfig: HotkeyRecognizerConfig) {
        self.config = newConfig
    }

    // MARK: - Input

    /// Feed a raw event. Before handling, we lazily expire any pending double-tap whose window
    /// has elapsed by this event's timestamp — so correctness never depends on the timer.
    func handle(_ event: HotkeyEvent) {
        expirePendingIfNeeded(now: event.timestamp)

        // Escape: cancel only while recording (brief §2). Only on key-down.
        if event.keyCode == config.escapeKeyCode && event.kind == .keyDown && event.isDown {
            if isRecordingActive {
                emit(.cancel)
                state = .idle
            }
            return
        }

        // Paste-last combo: Left Cmd + configured key, on key-down. Independent of recording.
        if let paste = config.pasteHotkey,
           event.kind == .keyDown, event.isDown,
           event.keyCode == paste.keyCode,
           hasLeftCommand(event.modifiers) {
            emit(.pasteLastTranscript)
            return
        }

        // Trigger key (modifier-only, matched by keyCode). flagsChanged carries isDown.
        if event.keyCode == config.trigger.keyCode && isTriggerEvent(event) {
            if event.isDown {
                handleTriggerDown(at: event.timestamp)
            } else {
                handleTriggerUp(at: event.timestamp)
            }
        }
    }

    /// External clock nudge — call from a timer to expire a pending double-tap even when no
    /// further key events arrive. Safe to call at any time; a no-op unless a window has elapsed.
    func tick(now: TimeInterval) {
        expirePendingIfNeeded(now: now)
    }

    // MARK: - Trigger handling

    private func handleTriggerDown(at time: TimeInterval) {
        switch state {
        case .idle:
            // First press → start recording immediately (prompt PTT).
            emit(.pushToTalkBegan)
            state = .ptt

        case .ptt:
            // Duplicate down without an intervening up (key-repeat on a held modifier, or a
            // lost up). Ignore — we're already recording and holding.
            break

        case let .pendingDoubleTap(releaseTime):
            // Second tap within the window → upgrade the live recording to locked.
            // (expirePendingIfNeeded already ran, so if we're still pending the window holds.)
            _ = releaseTime
            emit(.lockToggledOn)
            state = .locked

        case .locked:
            // Any press while locked = stop (tap or the start of a hold; Appendix C).
            // (A *quick* third tap of a triple is caught in `.lockedPendingTriple`, which is
            // only entered once the lock tap is released — so a genuine stop-hold, whose
            // down we act on here immediately, is never mistaken for a triple.)
            emit(.lockToggledOff)
            emit(.pushToTalkEnded)
            state = .idle

        case let .lockedPendingTriple(lockReleaseTime):
            // Third quick tap within the window → informational "show microphone".
            // (expirePendingIfNeeded already ran; still-pending means the window holds.)
            // The locked recording is untouched — we return to `.locked` and the newly
            // pressed trigger, once released, will not fire again (see handleTriggerUp).
            _ = lockReleaseTime
            emit(.showMicrophone)
            state = .locked
        }
    }

    private func handleTriggerUp(at time: TimeInterval) {
        switch state {
        case .ptt:
            // Released. Enter the pending window; recording stays live meanwhile. We defer the
            // stop so a fast second tap can upgrade to lock without dropping audio.
            state = .pendingDoubleTap(releaseTime: time)

        case .locked:
            // Release of the lock tap (or of the 3rd tap that re-showed the mic). Enter the
            // triple-watch window: a further quick tap fires `.showMicrophone`. Recording stays
            // live throughout. If the window expires with no further down we settle back to
            // `.locked` (a plain double-tap-lock), so a *later* tap correctly stops.
            state = .lockedPendingTriple(lockReleaseTime: time)

        case .idle, .pendingDoubleTap, .lockedPendingTriple:
            // idle: stray up. No-op.
            // pendingDoubleTap: a second up without a second down — shouldn't happen, ignore.
            // lockedPendingTriple: a stray extra up while already watching — ignore.
            break
        }
    }

    // MARK: - Pending expiry

    private func expirePendingIfNeeded(now: TimeInterval) {
        switch state {
        case let .pendingDoubleTap(releaseTime):
            if now - releaseTime >= config.doubleTapWindow {
                // Window elapsed with no second tap → the short press was a genuine brief PTT.
                emit(.pushToTalkEnded)
                state = .idle
            }
        case let .lockedPendingTriple(lockReleaseTime):
            if now - lockReleaseTime >= config.doubleTapWindow {
                // Window elapsed with no third tap → a plain double-tap-lock. Settle back to
                // `.locked` (recording untouched); no gesture. A later tap now stops normally.
                state = .locked
            }
        case .idle, .ptt, .locked:
            break
        }
    }

    // MARK: - Helpers

    private func emit(_ gesture: HotkeyGesture) { onGesture(gesture) }

    /// Whether an event should be treated as the trigger. Modifier-only triggers come as
    /// `flagsChanged`; a keyboard-key trigger comes as keyDown/keyUp.
    private func isTriggerEvent(_ event: HotkeyEvent) -> Bool {
        if config.trigger.isModifierOnlyTrigger {
            return event.kind == .flagsChanged
        }
        return event.kind == .keyDown || event.kind == .keyUp
    }

    private func hasLeftCommand(_ modifiers: UInt64) -> Bool {
        (modifiers & ModifierMask.command) != 0 || (modifiers & ModifierMask.leftCommandDevice) != 0
    }
}
