import XCTest
@testable import Soro

/// Adversarial tests for the layers ABOVE the pure recognizer: the gesture→coordinator dispatch
/// (AppState) and the CGEventTap-flag derivation (HotkeyManager). Two real bugs were found and
/// fixed here; these are the regression guards.
@MainActor
final class HotkeyDispatchTests: XCTestCase {

    // MARK: - Coordinator construction helper

    private func makeCoordinator() -> (DictationCoordinator, AppPaths) {
        let paths = makeTempPaths()
        let prefs = PreferencesStore(paths: paths)
        let coordinator = DictationCoordinator(
            audio: StubAudioCaptureService(),
            transcription: StubTranscriptionService(),
            cleanup: StubCleanupService(),
            insertion: StubInsertionService(),
            glossary: GlossaryStore(paths: paths),
            transcripts: TranscriptStore(paths: paths),
            stats: StatsStore(paths: paths),
            autoDict: AutoDictionaryStore(paths: paths),
            personalization: PersonalizationStore(paths: paths),
            preferences: prefs,
            styleSamples: StyleSampleStore(paths: paths),
            recordingWriter: RecordingWriter(paths: paths))
        return (coordinator, paths)
    }

    // MARK: - BUG A: markLocked upgrade depends on strict began→lockOn ordering

    /// The double-tap-lock upgrade path (`began` then `lockOn` on the same live session) only works
    /// if the two gestures are applied IN ORDER. This proves the ordering is load-bearing: reversing
    /// it drops the lock. AppState now dispatches synchronously/FIFO instead of via independent
    /// `Task`s (which have no ordering guarantee), so the correct order is preserved.
    func testMarkLockedUpgrade_requiresOrderedBeganThenLockOn() {
        let (c, paths) = makeCoordinator(); defer { removeTemp(paths) }
        // Correct order: begin, then lock -> ends up LOCKED.
        c.beginRecording(locked: false)
        c.markLocked()
        XCTAssertEqual(c.state, .recording(locked: true))
    }

    /// If the order were ever reversed (the bug the AppState fix prevents), markLocked would be a
    /// no-op and the session would stay unlocked. Documenting the failure mode so the guarantee is
    /// explicit.
    func testMarkLockedBeforeBegin_isNoOp_provingOrderMatters() {
        let (c, paths) = makeCoordinator(); defer { removeTemp(paths) }
        c.markLocked()                                   // arrives first (the bug scenario)
        XCTAssertEqual(c.state, .idle)                   // dropped — nothing to lock
        c.beginRecording(locked: false)
        XCTAssertEqual(c.state, .recording(locked: false))  // stays UNLOCKED — lock was lost
    }

    // MARK: - BUG A (integration): AppState.dispatch is synchronous & ordered

    /// Feeding the exact double-tap gesture sequence through AppState.dispatch must leave the
    /// coordinator LOCKED — no reordering, no dropped lock.
    func testAppStateDispatch_doubleTapSequenceEndsLocked() {
        let app = AppState(paths: makeTempPaths())
        app.dispatch(.pushToTalkBegan)
        app.dispatch(.lockToggledOn)
        XCTAssertEqual(app.coordinator.state, .recording(locked: true))
    }

    /// A lock-then-stop sequence (lockOff then ended) must transition cleanly to transcribing and
    /// the trailing `ended` must be a harmless no-op (guarded) — no crash, no desync.
    func testAppStateDispatch_lockOffThenEnded_isOrderedAndSafe() {
        let app = AppState(paths: makeTempPaths())
        app.dispatch(.pushToTalkBegan)
        app.dispatch(.lockToggledOn)
        app.dispatch(.lockToggledOff)          // -> transcribing
        app.dispatch(.pushToTalkEnded)         // guarded no-op
        XCTAssertEqual(app.coordinator.state, .transcribing)
    }

    /// Cancel arriving in a non-recording (transcribing) state must NOT crash and must not resurrect
    /// idle/recording — guarded no-op (brief §2: Esc cancels *recording*).
    func testAppStateDispatch_cancelDuringTranscribing_isSafeNoOp() {
        let app = AppState(paths: makeTempPaths())
        app.dispatch(.pushToTalkBegan)
        app.dispatch(.pushToTalkEnded)         // -> transcribing
        app.dispatch(.cancel)                  // must be a safe no-op, not a crash
        XCTAssertEqual(app.coordinator.state, .transcribing)
    }

    // MARK: - BUG B: left/right modifier disambiguation via device flags

    private func flags(_ raw: UInt64) -> CGEventFlags { CGEventFlags(rawValue: raw) }

    // Device bits: leftAlt 0x20, rightAlt 0x40; generic alternate mask 0x00080000.
    private let genericAlt: UInt64 = 0x0008_0000
    private let leftAltBit: UInt64 = 0x20
    private let rightAltBit: UInt64 = 0x40

    /// Left-Option down (its own device bit set) reads as DOWN for a Left-Option trigger.
    func testLeftOptionDown_readsDown() {
        let f = flags(genericAlt | leftAltBit)
        XCTAssertTrue(HotkeyManager.modifierBitSet(for: .leftOption, flags: f))
    }

    /// THE BUG: Left Option held AND Right Option pressed, then Left released. The release event
    /// still shows the generic `.maskAlternate` (right side still down), but the LEFT device bit is
    /// clear. Old code returned `true` (stuck recording); fixed code returns `false` (a real release).
    func testLeftOptionRelease_whileRightStillHeld_readsUp() {
        // After left-up: generic alt still set (right down), left bit cleared, right bit set.
        let f = flags(genericAlt | rightAltBit)
        XCTAssertFalse(HotkeyManager.modifierBitSet(for: .leftOption, flags: f),
                       "Left-Option release must read as UP even while Right Option is held")
    }

    /// Right Option pressed while Left-Option is the trigger must NOT read as the trigger being down
    /// (prevents a right-key press from spuriously driving a left-only binding via the shared mask).
    func testRightOptionDown_doesNotReadAsLeftTriggerDown() {
        let f = flags(genericAlt | rightAltBit)   // only right side physically down
        XCTAssertFalse(HotkeyManager.modifierBitSet(for: .leftOption, flags: f))
    }

    /// Symmetry: a Right-Option trigger reads its own side correctly and ignores the left side.
    func testRightOptionTrigger_readsOwnSideOnly() {
        let rightOpt = HotkeyData(keyCode: 61, keyName: "Right Option",
                                  isModifierOnlyTrigger: true, isRightModifier: true)
        XCTAssertTrue(HotkeyManager.modifierBitSet(for: rightOpt, flags: flags(genericAlt | rightAltBit)))
        XCTAssertFalse(HotkeyManager.modifierBitSet(for: rightOpt, flags: flags(genericAlt | leftAltBit)))
    }

    /// Backward-compat fallback: a source that reports ONLY the generic mask (no device bits, e.g.
    /// some synthetic/remapped events) still reads as down — keyCode gating upstream ensures the
    /// event belongs to the trigger.
    func testGenericMaskOnly_fallsBackToDown() {
        XCTAssertTrue(HotkeyManager.modifierBitSet(for: .leftOption, flags: flags(genericAlt)))
    }

    /// No modifiers at all → up.
    func testNoFlags_readsUp() {
        XCTAssertFalse(HotkeyManager.modifierBitSet(for: .leftOption, flags: flags(0)))
    }
}
