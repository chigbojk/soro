import XCTest
@testable import Soro

/// Pure-logic tests for the M5 recording bar: frame persistence codec and the
/// state → visibility mapping. Visual fidelity is verified by the orchestrator.
final class RecordingBarModelTests: XCTestCase {

    // MARK: Frame persistence encode / decode

    func testEncodeDecodeRoundTrip() throws {
        let rect = CGRect(x: 100.5, y: -20, width: 260, height: 44)
        let encoded = RecordingBarModel.encodeFrame(rect)
        let decoded = try XCTUnwrap(RecordingBarModel.decodeFrame(encoded))
        XCTAssertEqual(decoded.origin.x, rect.origin.x, accuracy: 0.0001)
        XCTAssertEqual(decoded.origin.y, rect.origin.y, accuracy: 0.0001)
        XCTAssertEqual(decoded.size.width, rect.size.width, accuracy: 0.0001)
        XCTAssertEqual(decoded.size.height, rect.size.height, accuracy: 0.0001)
    }

    func testDecodeRejectsMalformed() {
        XCTAssertNil(RecordingBarModel.decodeFrame(nil))
        XCTAssertNil(RecordingBarModel.decodeFrame(""))
        XCTAssertNil(RecordingBarModel.decodeFrame("1,2,3"))          // too few
        XCTAssertNil(RecordingBarModel.decodeFrame("1,2,3,4,5"))      // too many
        XCTAssertNil(RecordingBarModel.decodeFrame("a,b,c,d"))        // non-numeric
        XCTAssertNil(RecordingBarModel.decodeFrame("1,2,0,44"))       // zero width
        XCTAssertNil(RecordingBarModel.decodeFrame("1,2,260,-1"))     // negative height
        XCTAssertNil(RecordingBarModel.decodeFrame("1,2,inf,44"))     // non-finite
    }

    func testDecodeTolueratesWhitespace() throws {
        let decoded = try XCTUnwrap(RecordingBarModel.decodeFrame(" 10 , 20 , 260 , 44 "))
        XCTAssertEqual(decoded, CGRect(x: 10, y: 20, width: 260, height: 44))
    }

    // MARK: State → phase mapping

    func testMasterSwitchesForceHidden() {
        // enableNotchView off → always hidden.
        XCTAssertEqual(
            RecordingBarModel.phase(for: .recording(locked: true),
                                    notchEnabled: false, hideBar: false, hideBarWhenIdle: false),
            .hidden)
        // hideBar → always hidden even while recording.
        XCTAssertEqual(
            RecordingBarModel.phase(for: .recording(locked: false),
                                    notchEnabled: true, hideBar: true, hideBarWhenIdle: false),
            .hidden)
    }

    func testIdleMapping() {
        XCTAssertEqual(
            RecordingBarModel.phase(for: .idle, notchEnabled: true, hideBar: false, hideBarWhenIdle: true),
            .hidden)
        XCTAssertEqual(
            RecordingBarModel.phase(for: .idle, notchEnabled: true, hideBar: false, hideBarWhenIdle: false),
            .dormant)
    }

    func testRecordingPreservesLock() {
        XCTAssertEqual(
            RecordingBarModel.phase(for: .recording(locked: true),
                                    notchEnabled: true, hideBar: false, hideBarWhenIdle: true),
            .recording(locked: true))
        XCTAssertEqual(
            RecordingBarModel.phase(for: .recording(locked: false),
                                    notchEnabled: true, hideBar: false, hideBarWhenIdle: true),
            .recording(locked: false))
    }

    func testTranscribingAndInsertingHideBar() {
        // De-duped: the top-right toast owns post-recording status now, so the
        // island retreats the instant recording stops.
        for state in [DictationState.transcribing, .inserting] {
            XCTAssertEqual(
                RecordingBarModel.phase(for: state, notchEnabled: true, hideBar: false, hideBarWhenIdle: true),
                .hidden)
        }
    }

    func testDoneAndErrorBothHide() {
        // Both terminal states hide the bar; the toast shows Pasted/Failed.
        XCTAssertEqual(
            RecordingBarModel.phase(for: .done, notchEnabled: true, hideBar: false, hideBarWhenIdle: true),
            .hidden)
        XCTAssertEqual(
            RecordingBarModel.phase(for: .error("boom"), notchEnabled: true, hideBar: false, hideBarWhenIdle: true),
            .hidden)
    }

    func testOnlyDormantAndRecordingAreEverVisible() {
        // Exhaustively: across every DictationState, phase(for:) resolves only to
        // .hidden / .dormant / .recording — never .transcribing / .doneFlash.
        let states: [DictationState] = [
            .idle, .recording(locked: false), .recording(locked: true),
            .transcribing, .inserting, .done, .error("x")
        ]
        for s in states {
            let p = RecordingBarModel.phase(for: s, notchEnabled: true,
                                            hideBar: false, hideBarWhenIdle: false)
            switch p {
            case .hidden, .dormant, .recording:
                break
            case .transcribing, .doneFlash:
                XCTFail("phase(for:) must never surface \(p)")
            }
        }
    }

    // MARK: Visibility / helper predicates

    func testIsVisible() {
        XCTAssertFalse(RecordingBarModel.isVisible(.hidden))
        XCTAssertTrue(RecordingBarModel.isVisible(.dormant))
        XCTAssertTrue(RecordingBarModel.isVisible(.recording(locked: false)))
        XCTAssertTrue(RecordingBarModel.isVisible(.transcribing))
        XCTAssertTrue(RecordingBarModel.isVisible(.doneFlash))
    }

    func testIsRecordingPhaseAndLock() {
        XCTAssertTrue(RecordingBarModel.isRecordingPhase(.recording(locked: false)))
        XCTAssertFalse(RecordingBarModel.isRecordingPhase(.transcribing))
        XCTAssertTrue(RecordingBarModel.showsLock(.recording(locked: true)))
        XCTAssertFalse(RecordingBarModel.showsLock(.recording(locked: false)))
        XCTAssertFalse(RecordingBarModel.showsLock(.dormant))
    }

    // MARK: Placement + clamp

    func testDefaultOriginCentersUnderTop() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 260, height: 44)
        let origin = RecordingBarModel.defaultOrigin(in: screen, size: size, topInset: 8)
        XCTAssertEqual(origin.x, 720 - 130, accuracy: 0.0001)          // centered
        XCTAssertEqual(origin.y, 900 - 44 - 8, accuracy: 0.0001)       // near top (maxY)
    }

    func testClampKeepsBarPartlyOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offLeft = CGRect(x: -1000, y: 400, width: 260, height: 44)
        let clampedLeft = RecordingBarModel.clamp(offLeft, to: screen, minVisible: 40)
        XCTAssertGreaterThanOrEqual(clampedLeft.maxX, screen.minX + 40)

        let offRight = CGRect(x: 5000, y: 400, width: 260, height: 44)
        let clampedRight = RecordingBarModel.clamp(offRight, to: screen, minVisible: 40)
        XCTAssertLessThanOrEqual(clampedRight.origin.x, screen.maxX - 40)

        // A fully on-screen frame is left untouched.
        let onScreen = CGRect(x: 100, y: 100, width: 260, height: 44)
        XCTAssertEqual(RecordingBarModel.clamp(onScreen, to: screen), onScreen)
    }

    // MARK: Timer + waveform helpers

    func testElapsedLabelFormatting() {
        XCTAssertEqual(RecordingBarModel.elapsedLabel(0), "0:00")
        XCTAssertEqual(RecordingBarModel.elapsedLabel(5), "0:05")
        XCTAssertEqual(RecordingBarModel.elapsedLabel(65), "1:05")
        XCTAssertEqual(RecordingBarModel.elapsedLabel(600), "10:00")
        XCTAssertEqual(RecordingBarModel.elapsedLabel(-3), "0:00")     // never negative
    }

    // MARK: Notch geometry

    func testNotchCenterFromAuxAreaMirrorsToScreenCenter() {
        // 1512-wide notched display (14" MBP); aux-left area ends at the notch's
        // left edge. Center should land on the display midpoint.
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let cx = RecordingBarModel.notchCenterX(fullFrame: full,
                                                auxLeftMaxX: 656, // notch left edge
                                                safeAreaLeftInset: 0)
        XCTAssertEqual(cx, 756, accuracy: 0.5)   // == full.midX
    }

    func testNotchCenterOffsetDisplayHonorsAuxEdge() {
        // External/offset display whose frame does not start at x=0.
        let full = CGRect(x: 100, y: 0, width: 1000, height: 800)
        let cx = RecordingBarModel.notchCenterX(fullFrame: full,
                                                auxLeftMaxX: 550,
                                                safeAreaLeftInset: 0)
        // leftEdge=550, rightEdge=1100-(550-100)=650 → center 600 == midX
        XCTAssertEqual(cx, 600, accuracy: 0.5)
    }

    func testNotchCenterFallsBackToMidXWithoutAux() {
        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(
            RecordingBarModel.notchCenterX(fullFrame: full, auxLeftMaxX: nil),
            720, accuracy: 0.5)
        // Aux maxX outside the frame is ignored (defensive).
        XCTAssertEqual(
            RecordingBarModel.notchCenterX(fullFrame: full, auxLeftMaxX: 5000),
            720, accuracy: 0.5)
        // A left safe-area inset alone still centers on midX.
        XCTAssertEqual(
            RecordingBarModel.notchCenterX(fullFrame: full, auxLeftMaxX: nil, safeAreaLeftInset: 40),
            720, accuracy: 0.5)
    }

    func testPillWidthIsWide() {
        // The redesigned pill must be substantially wider than the old 260 bar so
        // it flanks both sides of the notch.
        XCTAssertGreaterThanOrEqual(RecordingBarModel.pillWidth, 320)
    }

    // MARK: Dynamic-Island geometry

    func testTopFlushOriginPinsTopEdgeToScreenTop() {
        // Full frame (NOT visibleFrame); top edge must sit exactly at frame.maxY.
        let full = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let size = CGSize(width: 536, height: RecordingBarModel.pillHeight)
        let origin = RecordingBarModel.topFlushOrigin(in: full, size: size, centerX: 864)
        // y = maxY - height (flush, topInset 0) → top edge (y+height) == maxY.
        XCTAssertEqual(origin.y, full.maxY - size.height, accuracy: 0.0001)
        XCTAssertEqual(origin.y + size.height, full.maxY, accuracy: 0.0001)
        // Centered on the notch center.
        XCTAssertEqual(origin.x, 864 - size.width / 2, accuracy: 0.0001)
    }

    func testNotchWidthFromExactAuxEdges() {
        // Measured target Mac: 1728 wide, notch ~200pt centered on midX 864 →
        // left edge 764, right edge 964.
        let full = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let w = RecordingBarModel.notchWidth(fullFrame: full,
                                             auxLeftMaxX: 764,
                                             auxRightMinX: 964,
                                             safeAreaTopInset: 32)
        XCTAssertEqual(w, 200, accuracy: 0.5)
    }

    func testNotchWidthMirrorsWhenOnlyLeftEdgeKnown() {
        let full = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let w = RecordingBarModel.notchWidth(fullFrame: full,
                                             auxLeftMaxX: 764,
                                             auxRightMinX: nil,
                                             safeAreaTopInset: 32)
        // (midX 864 - 764) * 2 == 200
        XCTAssertEqual(w, 200, accuracy: 0.5)
    }

    func testNotchWidthFallsBackWhenOnlyTopInset() {
        let full = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertEqual(
            RecordingBarModel.notchWidth(fullFrame: full, auxLeftMaxX: nil,
                                         auxRightMinX: nil, safeAreaTopInset: 32),
            RecordingBarModel.fallbackNotchWidth, accuracy: 0.001)
    }

    func testNotchWidthZeroOnNonNotchedMac() {
        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(
            RecordingBarModel.notchWidth(fullFrame: full, auxLeftMaxX: nil,
                                         auxRightMinX: nil, safeAreaTopInset: 0),
            0, accuracy: 0.001)
    }

    func testPillWidthMathFlanksNotch() {
        // Total = gap + 2 * sideZone.
        let w = RecordingBarModel.pillWidth(notchGap: 200, sideZone: 168)
        XCTAssertEqual(w, 200 + 2 * 168, accuracy: 0.001)
        // Non-notched: collapses to a plain centered pill (no gap).
        let plain = RecordingBarModel.pillWidth(notchGap: 0, sideZone: 168)
        XCTAssertEqual(plain, 2 * 168, accuracy: 0.001)
    }

    // MARK: Stale-frame rejection

    func testPersistedFrameIgnoredWhenUserNeverMoved() {
        let size = CGSize(width: RecordingBarModel.pillWidth, height: RecordingBarModel.pillHeight)
        let saved = CGRect(x: 100, y: 200, width: size.width, height: size.height)
        // Size matches but the user never moved it → re-derive, don't adopt.
        XCTAssertFalse(RecordingBarModel.shouldAdoptPersistedFrame(saved, currentSize: size, userMoved: false))
        // Same frame, user did move it → adopt.
        XCTAssertTrue(RecordingBarModel.shouldAdoptPersistedFrame(saved, currentSize: size, userMoved: true))
    }

    func testStalePersistedFrameSizeMismatchRejected() {
        let size = CGSize(width: RecordingBarModel.pillWidth, height: RecordingBarModel.pillHeight)
        // Old build saved a 120×38 pill — must be ignored even if user "moved" it.
        let stale = CGRect(x: 100, y: 200, width: 120, height: 38)
        XCTAssertFalse(RecordingBarModel.shouldAdoptPersistedFrame(stale, currentSize: size, userMoved: true))
        // Sub-point rounding still adopts.
        let rounded = CGRect(x: 100, y: 200, width: size.width + 0.3, height: size.height - 0.2)
        XCTAssertTrue(RecordingBarModel.shouldAdoptPersistedFrame(rounded, currentSize: size, userMoved: true))
    }

    func testDefaultOriginHonorsNotchCenter() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let size = CGSize(width: RecordingBarModel.pillWidth, height: RecordingBarModel.pillHeight)
        let origin = RecordingBarModel.defaultOrigin(in: visible, size: size, centerX: 756)
        XCTAssertEqual(origin.x, 756 - size.width / 2, accuracy: 0.0001)
        // Nil centerX falls back to visible.midX.
        let fallback = RecordingBarModel.defaultOrigin(in: visible, size: size)
        XCTAssertEqual(fallback.x, visible.midX - size.width / 2, accuracy: 0.0001)
    }

    // MARK: Left-icon fallback

    func testLeftIconFallsBackToMic() {
        XCTAssertEqual(RecordingBarModel.leftIcon(hasCapturedIcon: false), .micFallback)
        XCTAssertEqual(RecordingBarModel.leftIcon(hasCapturedIcon: true), .appIcon)
    }

    @MainActor
    func testLeftIconProviderCaptureAndClear() {
        // Inject a deterministic resolver so no live NSWorkspace is needed.
        let stub = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        let provider = LeftIconProvider(resolveFrontmostIcon: { stub })
        XCTAssertNil(provider.icon)
        XCTAssertFalse(provider.hasIcon)
        provider.captureFrontmost()
        XCTAssertNotNil(provider.icon)
        XCTAssertTrue(provider.hasIcon)
        provider.clear()
        XCTAssertNil(provider.icon)
    }

    @MainActor
    func testLeftIconProviderNilResolverStaysMicFallback() {
        let provider = LeftIconProvider(resolveFrontmostIcon: { nil })
        provider.captureFrontmost()
        XCTAssertNil(provider.icon)
        XCTAssertEqual(RecordingBarModel.leftIcon(hasCapturedIcon: provider.hasIcon), .micFallback)
    }

    func testBarHeightFractionClampsAndFloors() {
        XCTAssertEqual(RecordingBarModel.barHeightFraction(forLevel: -1), 0.06, accuracy: 0.001)
        XCTAssertEqual(RecordingBarModel.barHeightFraction(forLevel: 0.01, floor: 0.06), 0.06, accuracy: 0.001)
        XCTAssertLessThanOrEqual(RecordingBarModel.barHeightFraction(forLevel: 2), 1)
        let mid = RecordingBarModel.barHeightFraction(forLevel: 0.5)
        XCTAssertGreaterThan(mid, 0.06)
        XCTAssertLessThan(mid, 1)
    }
}
