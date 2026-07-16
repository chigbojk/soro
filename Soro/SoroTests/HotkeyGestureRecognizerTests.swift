import XCTest
@testable import Soro

/// Exhaustive tests for the pure push-to-talk / double-tap-lock state machine (brief §2,
/// Appendix C). This is the correctness-critical piece under adversarial review.
final class HotkeyGestureRecognizerTests: XCTestCase {

    // MARK: - Harness

    private let triggerKey: UInt16 = 58   // Left Option
    private let window: TimeInterval = 0.28

    private func makeRecognizer(
        pasteHotkey: HotkeyData? = nil,
        window: TimeInterval? = nil
    ) -> (HotkeyGestureRecognizer, () -> [HotkeyGesture]) {
        var captured: [HotkeyGesture] = []
        let config = HotkeyRecognizerConfig(
            trigger: .leftOption,
            pasteHotkey: pasteHotkey,
            doubleTapWindow: window ?? self.window
        )
        let r = HotkeyGestureRecognizer(config: config) { captured.append($0) }
        return (r, { captured })
    }

    private func triggerDown(_ r: HotkeyGestureRecognizer, at t: TimeInterval) {
        r.handle(HotkeyEvent(kind: .flagsChanged, keyCode: triggerKey, isDown: true, timestamp: t))
    }
    private func triggerUp(_ r: HotkeyGestureRecognizer, at t: TimeInterval) {
        r.handle(HotkeyEvent(kind: .flagsChanged, keyCode: triggerKey, isDown: false, timestamp: t))
    }
    private func esc(_ r: HotkeyGestureRecognizer, at t: TimeInterval) {
        r.handle(HotkeyEvent(kind: .keyDown, keyCode: 53, isDown: true, timestamp: t))
    }

    // Equatable helper for HotkeyGesture (enum has no payloads, so map to strings).
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

    // MARK: - Push-to-talk (hold)

    func testPressAndHoldStartsRecordingImmediately() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        // Recording must begin on the very first down — no waiting out the window.
        XCTAssertEqual(names(out()), ["began"])
        XCTAssertTrue(r.isRecordingActive)
    }

    func testHoldThenReleaseAfterWindowIsCleanPTT_neverLocks() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        // Hold well past the double-tap window, then release.
        triggerUp(r, at: 0.0 + window + 0.5)
        // Release enters pending; but since it's long past window it must resolve to ended,
        // not lock. Nudge the clock forward (as the manager's timer would).
        r.tick(now: window + 0.5 + window + 0.01)
        XCTAssertEqual(names(out()), ["began", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    func testSlowHoldNeverRegistersAsDoubleTap() {
        // A slow single hold: down, long hold, up. Even if a *late* second down arrives after
        // the window, it must be a NEW ptt, not a lock upgrade.
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 1.0)                  // released far past window
        // Window expires -> ended.
        r.tick(now: 1.0 + window + 0.01)
        // A later down starts a fresh PTT.
        triggerDown(r, at: 2.0)
        XCTAssertEqual(names(out()), ["began", "ended", "began"])
    }

    // MARK: - Short tap PTT (release before window)

    func testQuickTapReleaseBeforeWindowStillYieldsShortPTT_notSwallowed() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)                 // released well within the window
        // No second tap. The window must expire into a real short PTT (record-and-stop), not a
        // swallowed input.
        r.tick(now: 0.05 + window + 0.001)
        XCTAssertEqual(names(out()), ["began", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    func testQuickTap_expiresLazilyOnNextEventWithoutTimer() {
        // Even if the manager's timer never fires, the next incoming event must expire the pending
        // window so nothing is left dangling.
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)
        // A brand new press arrives long after the window — the pending PTT must have expired
        // (ended) and this must start a fresh recording.
        triggerDown(r, at: 1.0)
        XCTAssertEqual(names(out()), ["began", "ended", "began"])
    }

    // MARK: - Double-tap lock

    func testFastDoubleTapLocks() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)                // began
        triggerUp(r, at: 0.05)                 // pending
        triggerDown(r, at: 0.10)               // 2nd tap within window -> lock
        XCTAssertEqual(names(out()), ["began", "lockOn"])
        XCTAssertTrue(r.isRecordingActive)
        // No duplicate "began" — the live recording is kept, not restarted.
        XCTAssertEqual(names(out()).filter { $0 == "began" }.count, 1)
    }

    func testDoubleTapUpEventAfterLockDoesNotStop() {
        // After locking, the up of the second tap must NOT stop recording.
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)
        triggerDown(r, at: 0.10)               // lockOn
        triggerUp(r, at: 0.15)                 // release of 2nd tap — must be ignored
        XCTAssertEqual(names(out()), ["began", "lockOn"])
        XCTAssertTrue(r.isRecordingActive)
    }

    func testSecondTapJustOutsideWindowDoesNotLock_startsFreshPTT() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)
        // Second down arrives *after* release + window -> too slow; the first press already
        // ended as PTT, and this becomes a new PTT.
        let late = 0.05 + window + 0.001
        triggerDown(r, at: late)
        XCTAssertEqual(names(out()), ["began", "ended", "began"])
    }

    func testSecondTapExactlyAtWindowBoundaryDoesNotLock() {
        // Boundary is inclusive on expiry (>= window). At exactly release+window the pending PTT
        // has expired, so the second down is a fresh PTT, not a lock.
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)
        triggerDown(r, at: 0.05 + window)
        XCTAssertEqual(names(out()), ["began", "ended", "began"])
    }

    // MARK: - Tap-then-hold disambiguation

    func testTapThenHoldLocks_andHoldDoesNotAddSpuriousGestures() {
        // Tap, then a quick second press that is HELD. The second down within window still locks.
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.04)                 // pending
        triggerDown(r, at: 0.08)               // 2nd within window, then held -> lock
        // Hold the second key a long time; ticks must not change anything while locked.
        r.tick(now: 5.0)
        XCTAssertEqual(names(out()), ["began", "lockOn"])
        XCTAssertTrue(r.isRecordingActive)
    }

    // MARK: - Locked semantics

    func testLockThenSingleTapStops() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)
        triggerDown(r, at: 0.10)               // lockOn
        triggerUp(r, at: 0.15)                 // ignored
        // A later single press stops.
        triggerDown(r, at: 2.0)                // lockOff + ended
        XCTAssertEqual(names(out()), ["began", "lockOn", "lockOff", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    func testLockThenHoldStops_holdTreatedAsStop() {
        // Appendix C: while locked, holding instead of tapping is still "stop" (acts on down).
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)
        triggerDown(r, at: 0.10)               // lockOn
        triggerUp(r, at: 0.15)
        triggerDown(r, at: 3.0)                // press to stop
        triggerUp(r, at: 5.0)                  // long hold then release — no extra gestures
        XCTAssertEqual(names(out()), ["began", "lockOn", "lockOff", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    // MARK: - Escape

    func testEscWhileRecordingCancels() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)                // began
        esc(r, at: 0.1)                        // cancel
        XCTAssertEqual(names(out()), ["began", "cancel"])
        XCTAssertFalse(r.isRecordingActive)
    }

    func testEscWhileIdleDoesNothing() {
        let (r, out) = makeRecognizer()
        esc(r, at: 0.0)
        XCTAssertEqual(names(out()), [])
    }

    func testEscWhileLockedCancels() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)
        triggerDown(r, at: 0.10)               // lockOn
        esc(r, at: 0.5)                         // cancel
        XCTAssertEqual(names(out()), ["began", "lockOn", "cancel"])
        XCTAssertFalse(r.isRecordingActive)
    }

    func testEscDuringPendingDoubleTapCancels() {
        // Esc while in the pending window must cancel the live recording (not leak a PTT).
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.05)                 // pending, recording still live
        esc(r, at: 0.08)                        // cancel
        XCTAssertEqual(names(out()), ["began", "cancel"])
        XCTAssertFalse(r.isRecordingActive)
        // A subsequent stray second down must NOT lock (state was reset to idle) — it's a new PTT.
        triggerDown(r, at: 0.10)
        XCTAssertEqual(names(out()), ["began", "cancel", "began"])
    }

    // MARK: - Paste-last combo

    func testPasteLastComboEmitsWithLeftCommand() {
        let paste = HotkeyData(keyCode: 9, keyName: "V", isModifierOnlyTrigger: false)
        let (r, out) = makeRecognizer(pasteHotkey: paste)
        // Left Cmd device bit (0x8) + generic command bit set.
        r.handle(HotkeyEvent(kind: .keyDown, keyCode: 9, modifiers: 0x0010_0008, isDown: true, timestamp: 0.0))
        XCTAssertEqual(names(out()), ["paste"])
    }

    func testPasteComboIgnoredWithoutCommand() {
        let paste = HotkeyData(keyCode: 9, keyName: "V", isModifierOnlyTrigger: false)
        let (r, out) = makeRecognizer(pasteHotkey: paste)
        r.handle(HotkeyEvent(kind: .keyDown, keyCode: 9, modifiers: 0, isDown: true, timestamp: 0.0))
        XCTAssertEqual(names(out()), [])
    }

    func testPasteComboNilConfigDoesNothing() {
        let (r, out) = makeRecognizer(pasteHotkey: nil)
        r.handle(HotkeyEvent(kind: .keyDown, keyCode: 9, modifiers: 0x0010_0008, isDown: true, timestamp: 0.0))
        XCTAssertEqual(names(out()), [])
    }

    // MARK: - Jittered / adversarial timestamps

    func testJitteredTimestampsDoubleTap() {
        // Slightly noisy but monotonic timestamps within window still lock.
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 10.0000)
        triggerUp(r, at: 10.0231)              // jitter
        triggerDown(r, at: 10.0475)            // within 0.28 of release
        XCTAssertEqual(names(out()), ["began", "lockOn"])
    }

    func testRepeatedDownWithoutUpIsIgnored() {
        // Key-repeat on a held modifier can deliver multiple downs with no up. Only one "began".
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.0)
        triggerDown(r, at: 0.02)
        triggerDown(r, at: 0.04)
        XCTAssertEqual(names(out()), ["began"])
        XCTAssertTrue(r.isRecordingActive)
    }

    func testStrayUpWhileIdleIsIgnored() {
        let (r, out) = makeRecognizer()
        triggerUp(r, at: 0.0)
        XCTAssertEqual(names(out()), [])
        XCTAssertFalse(r.isRecordingActive)
    }

    func testTickWhileIdleOrRecordingIsNoOp() {
        let (r, out) = makeRecognizer()
        r.tick(now: 5.0)                        // idle: nothing
        triggerDown(r, at: 6.0)                 // began, still held
        r.tick(now: 100.0)                      // holding: must not end
        XCTAssertEqual(names(out()), ["began"])
        XCTAssertTrue(r.isRecordingActive)
    }

    func testFullLifecycle_pttThenLater_lock_thenStop() {
        let (r, out) = makeRecognizer()
        // 1) A hold-PTT.
        triggerDown(r, at: 0.0)
        triggerUp(r, at: 0.5)
        r.tick(now: 0.5 + window + 0.01)        // ended
        // 2) A double-tap lock.
        triggerDown(r, at: 2.0)
        triggerUp(r, at: 2.04)
        triggerDown(r, at: 2.09)                // lockOn
        // 3) Stop.
        triggerDown(r, at: 5.0)                 // lockOff + ended
        XCTAssertEqual(names(out()),
                       ["began", "ended", "began", "lockOn", "lockOff", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    // MARK: - Triple-tap → show microphone (§ toasts-tripletap)

    /// Three quick taps within the window: the first two lock (began, lockOn), the third
    /// fires `showMicrophone` WITHOUT disturbing the locked recording.
    func testTripleTapEmitsShowMicrophone_andStaysLocked() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.00)                 // began
        triggerUp(r, at: 0.04)                   // pending
        triggerDown(r, at: 0.08)                 // lockOn
        triggerUp(r, at: 0.11)                   // -> lockedPendingTriple
        triggerDown(r, at: 0.15)                 // 3rd tap within window -> mic
        XCTAssertEqual(names(out()), ["began", "lockOn", "mic"])
        XCTAssertTrue(r.isRecordingActive)       // still locked/recording
    }

    /// After a triple-tap the recording stays locked; a subsequent single tap still STOPS it
    /// (the 3rd tap did not consume the "stop" affordance).
    func testTripleTapThenSingleTapStops() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.00)
        triggerUp(r, at: 0.04)
        triggerDown(r, at: 0.08)                 // lockOn
        triggerUp(r, at: 0.11)
        triggerDown(r, at: 0.15)                 // mic (3rd tap), -> locked
        triggerUp(r, at: 0.18)
        // Later single tap stops.
        triggerDown(r, at: 2.0)
        XCTAssertEqual(names(out()), ["began", "lockOn", "mic", "lockOff", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    /// A plain double-tap-lock whose SECOND (lock) tap is released must NOT accidentally emit
    /// `showMicrophone`: with no third tap the pending-triple window expires back to locked.
    func testDoubleTapLock_noThirdTap_neverShowsMic() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.00)
        triggerUp(r, at: 0.04)
        triggerDown(r, at: 0.08)                 // lockOn
        triggerUp(r, at: 0.11)                   // lockedPendingTriple
        // No third tap; window elapses.
        r.tick(now: 0.11 + window + 0.01)
        XCTAssertEqual(names(out()), ["began", "lockOn"])
        XCTAssertTrue(r.isRecordingActive)       // still locked
        // And a later tap now stops (proves we settled to .locked, not stuck pending).
        triggerDown(r, at: 1.0)
        XCTAssertEqual(names(out()), ["began", "lockOn", "lockOff", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    /// A slow third press (after the window) is NOT a triple — it stops the locked recording.
    func testThirdTapOutsideWindowStopsInsteadOfShowingMic() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.00)
        triggerUp(r, at: 0.04)
        triggerDown(r, at: 0.08)                 // lockOn
        triggerUp(r, at: 0.11)                   // lockedPendingTriple
        // Third down arrives just past the window from the lock release.
        triggerDown(r, at: 0.11 + window + 0.001)   // stop, not mic
        XCTAssertEqual(names(out()), ["began", "lockOn", "lockOff", "ended"])
        XCTAssertFalse(r.isRecordingActive)
    }

    /// Esc during the triple-watch window cancels the locked recording (no leaked mic gesture).
    func testEscDuringLockedPendingTripleCancels() {
        let (r, out) = makeRecognizer()
        triggerDown(r, at: 0.00)
        triggerUp(r, at: 0.04)
        triggerDown(r, at: 0.08)                 // lockOn
        triggerUp(r, at: 0.11)                   // lockedPendingTriple
        esc(r, at: 0.13)                         // cancel
        XCTAssertEqual(names(out()), ["began", "lockOn", "cancel"])
        XCTAssertFalse(r.isRecordingActive)
    }

    func testPendingExpiryReportedForTimerScheduling() throws {
        let (r, _) = makeRecognizer()
        triggerDown(r, at: 0.0)
        XCTAssertNil(r.pendingExpiry)           // holding: not pending
        triggerUp(r, at: 0.1)
        XCTAssertEqual(try XCTUnwrap(r.pendingExpiry), 0.1 + window, accuracy: 1e-9)
        XCTAssertTrue(r.isPendingDoubleTap)
    }
}
