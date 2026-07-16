import XCTest
@testable import Soro

/// Adversarial attack battery against the hotkey gesture engine (brief §2, Appendix C).
/// Each test documents an attack vector; comments mark whether the attack is SURVIVED
/// (pre-existing correct behavior, kept as a regression guard) or a BUG the review fixed.
final class HotkeyAdversarialTests: XCTestCase {

    private let triggerKey: UInt16 = 58     // Left Option
    private let rightOption: UInt16 = 61
    private let window: TimeInterval = 0.28

    private func makeRecognizer(
        trigger: HotkeyData = .leftOption,
        pasteHotkey: HotkeyData? = nil,
        window: TimeInterval? = nil
    ) -> (HotkeyGestureRecognizer, () -> [HotkeyGesture]) {
        var captured: [HotkeyGesture] = []
        let config = HotkeyRecognizerConfig(
            trigger: trigger,
            pasteHotkey: pasteHotkey,
            doubleTapWindow: window ?? self.window
        )
        let r = HotkeyGestureRecognizer(config: config) { captured.append($0) }
        return (r, { captured })
    }

    private func down(_ r: HotkeyGestureRecognizer, key: UInt16? = nil, at t: TimeInterval) {
        r.handle(HotkeyEvent(kind: .flagsChanged, keyCode: key ?? triggerKey, isDown: true, timestamp: t))
    }
    private func up(_ r: HotkeyGestureRecognizer, key: UInt16? = nil, at t: TimeInterval) {
        r.handle(HotkeyEvent(kind: .flagsChanged, keyCode: key ?? triggerKey, isDown: false, timestamp: t))
    }
    private func esc(_ r: HotkeyGestureRecognizer, at t: TimeInterval) {
        r.handle(HotkeyEvent(kind: .keyDown, keyCode: 53, isDown: true, timestamp: t))
    }
    private func names(_ gestures: [HotkeyGesture]) -> [String] {
        gestures.map { g in
            switch g {
            case .pushToTalkBegan: return "began"
            case .pushToTalkEnded: return "ended"
            case .lockToggledOn: return "lockOn"
            case .lockToggledOff: return "lockOff"
            case .cancel: return "cancel"
            case .pasteLastTranscript: return "paste"
            case .showMicrophone: return "mic"
            }
        }
    }

    // MARK: - Attack 1: Timing edges

    /// Three RAPID taps: first two lock, the third (within the window of the lock-tap release)
    /// is now a triple-tap → `.showMicrophone`, leaving the recording locked (§ toasts-tripletap).
    /// Must NOT deadlock or double-began. A *slower* third tap still stops — see the next test.
    func testThreeRapidTaps_lockThenShowMic_staysLocked() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.00); up(r, at: 0.03)     // began, pending
        down(r, at: 0.06); up(r, at: 0.09)     // lockOn, (up -> lockedPendingTriple)
        down(r, at: 0.12)                       // 3rd rapid tap within window -> showMic
        XCTAssertEqual(names(out()), ["began", "lockOn", "mic"])
        XCTAssertTrue(r.isRecordingActive)      // still locked; mic is informational only
    }

    /// Lock, then a DELIBERATE (post-window) tap stops — the triple-watch window must have
    /// lapsed so a genuine stop is never swallowed by the triple-tap feature.
    func testLockThenSlowTapStops_notMistakenForTriple() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.00); up(r, at: 0.03)     // began, pending
        down(r, at: 0.06); up(r, at: 0.09)     // lockOn, (up -> lockedPendingTriple)
        down(r, at: 0.09 + window + 0.05)       // well past window -> stop
        XCTAssertEqual(names(out()), ["began", "lockOn", "lockOff", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    /// tap-pause-tap where the second tap is just outside the window → must be TWO separate
    /// short PTTs, never a lock.
    func testTapPauseTap_outsideWindow_isTwoSeparatePTTs() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.00); up(r, at: 0.02)              // began, pending
        let late = 0.02 + window + 0.02
        down(r, at: late); up(r, at: late + 0.02)       // expire first (ended, began), pending
        r.tick(now: late + 0.02 + window + 0.01)        // second expires (ended)
        XCTAssertEqual(names(out()), ["began", "ended", "began", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    /// Sub-50ms accidental graze that never gets a second tap resolves to a (tiny) PTT, not a
    /// swallowed no-op — brief §2 "release-before-window still yields a valid short PTT".
    func testSubMillisecondGraze_isShortPTT_notSwallowed() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.000); up(r, at: 0.004)
        r.tick(now: 0.004 + window + 0.001)
        XCTAssertEqual(names(out()), ["began", "ended"])
    }

    /// Second tap at EXACTLY release+window does not lock (expiry is inclusive, >=).
    func testSecondTapExactlyAtBoundary_doesNotLock() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.0); up(r, at: 0.05)
        down(r, at: 0.05 + window)              // exactly boundary
        XCTAssertEqual(names(out()), ["began", "ended", "began"])
    }

    /// One nanosecond inside the boundary still locks.
    func testSecondTapOneNanoInsideBoundary_locks() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.0); up(r, at: 0.05)
        down(r, at: 0.05 + window - 1e-9)
        XCTAssertEqual(names(out()), ["began", "lockOn"])
    }

    // MARK: - Attack 2: Interleavings

    /// Right Option (keyCode 61) must NOT trigger when the binding is Left-only (keyCode 58).
    func testRightOptionDoesNotTrigger_whenBoundToLeft() {
        let (r, out) = makeRecognizer()
        down(r, key: rightOption, at: 0.0)
        up(r, key: rightOption, at: 0.1)
        XCTAssertEqual(names(out()), [])
        XCTAssertFalse(r.isRecordingActive)
    }

    /// A non-trigger keyDown while the trigger is held (Opt+key combo, e.g. typing é) must not
    /// disturb the live PTT session — only trigger-key events matter.
    func testOtherKeyWhileTriggerHeld_doesNotAbortOrDuplicate() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.0)                                                    // began (ptt)
        r.handle(HotkeyEvent(kind: .keyDown, keyCode: 9, isDown: true, timestamp: 0.05))   // 'v'
        r.handle(HotkeyEvent(kind: .keyUp, keyCode: 9, isDown: false, timestamp: 0.07))
        up(r, at: 0.1)                                                      // pending
        r.tick(now: 0.1 + window + 0.01)                                   // ended
        XCTAssertEqual(names(out()), ["began", "ended"])
    }

    /// Trigger press during an active LOCKED recording must STOP (not restart) — no second began.
    func testTriggerPressWhileLocked_stopsNeverRestarts() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.0); up(r, at: 0.04); down(r, at: 0.08)   // began, lockOn
        down(r, at: 1.0)                                        // stop
        XCTAssertEqual(names(out()), ["began", "lockOn", "lockOff", "ended"])
        XCTAssertEqual(names(out()).filter { $0 == "began" }.count, 1)
    }

    /// Esc when NOT recording must be swallowed by the recognizer as a no-op (it emits nothing;
    /// the manager passes the physical key through untouched via listenOnly tap).
    func testEscWhileIdle_emitsNothing() {
        let (r, out) = makeRecognizer()
        esc(r, at: 0.0)
        XCTAssertEqual(names(out()), [])
    }

    // MARK: - Attack 3: State-machine invariants

    /// No sequence may leave recording active with no way to stop it. After every possible
    /// terminal, a fresh trigger-down must still start a new session (no deadlock).
    func testNoDeadlock_afterCancelFreshDownStartsAgain() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.0)                        // began
        esc(r, at: 0.05)                        // cancel -> idle
        down(r, at: 0.1)                        // must began again
        XCTAssertEqual(names(out()), ["began", "cancel", "began"])
        XCTAssertTrue(r.isRecordingActive)
    }

    /// Never two `began` without an intervening `ended`/`cancel`.
    func testNoDoubleBegan_acrossLongInterleaving() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.0)            // began
        down(r, at: 0.01)          // key-repeat: ignored
        up(r, at: 0.02)            // pending
        down(r, at: 0.03)          // lockOn
        up(r, at: 0.04)            // ignored
        // Walk the gestures: every "began" must be followed (eventually) by ended/cancel/lockOn
        // before the next began. Here there is exactly one began.
        XCTAssertEqual(names(out()).filter { $0 == "began" }.count, 1)
    }

    /// isRecordingActive is always false in the terminal idle state and true whenever a session
    /// (ptt / pending / locked) is live — no desync between the flag and emitted gestures.
    func testIsRecordingActiveTracksEmittedGestures() {
        let (r, _) = makeRecognizer()
        XCTAssertFalse(r.isRecordingActive)
        down(r, at: 0.0);  XCTAssertTrue(r.isRecordingActive)     // ptt
        up(r, at: 0.02);   XCTAssertTrue(r.isRecordingActive)     // pending (still live)
        down(r, at: 0.05); XCTAssertTrue(r.isRecordingActive)     // locked
        down(r, at: 1.0);  XCTAssertFalse(r.isRecordingActive)    // stopped
    }

    // MARK: - Attack 4 (recognizer-visible): updateConfig while live

    /// Rebinding the trigger mid-session must not strand a live recording: the old trigger's
    /// release/stop path must still be reachable. Attack: change window while pending.
    func testUpdateConfigWhilePending_doesNotStrandRecording() {
        let (r, out) = makeRecognizer()
        down(r, at: 0.0); up(r, at: 0.02)          // pending, window 0.28
        r.updateConfig(HotkeyRecognizerConfig(trigger: .leftOption, doubleTapWindow: 0.10))
        // With the shorter window, the next event past 0.12 must expire the pending PTT.
        r.tick(now: 0.02 + 0.10 + 0.001)
        XCTAssertEqual(names(out()), ["began", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }
}
