import XCTest
@testable import Soro

/// Pure enqueue/expire logic for the transient toast system (§ toasts-tripletap).
/// A controllable clock closure lets us drive time deterministically — no timers, no
/// window server.
@MainActor
final class ToastCenterTests: XCTestCase {

    /// Mutable clock for the center under test.
    private final class Clock { var t: TimeInterval = 0 }

    private func makeCenter(maxVisible: Int = 4) -> (ToastCenter, Clock) {
        let clock = Clock()
        let center = ToastCenter(maxVisible: maxVisible, now: { clock.t })
        return (center, clock)
    }

    // MARK: - Enqueue + timestamping

    func testShowStampsShownAtFromClock() {
        let (center, clock) = makeCenter()
        clock.t = 5.0
        center.show("Hi", systemImage: "mic")
        XCTAssertEqual(center.toasts.count, 1)
        // remainingFraction at show time is 1 (nothing elapsed).
        XCTAssertEqual(center.toasts[0].remainingFraction(at: 5.0), 1.0, accuracy: 1e-9)
    }

    func testMultipleToastsStackInOrder() {
        let (center, _) = makeCenter()
        center.show("A", systemImage: "1.circle")
        center.show("B", systemImage: "2.circle")
        XCTAssertEqual(center.toasts.map(\.message), ["A", "B"])
    }

    // MARK: - Expiry (pure)

    func testExpireRemovesElapsedToasts() {
        let (center, clock) = makeCenter()
        clock.t = 0
        center.show("gone", systemImage: "x", duration: 3.0)
        // Not yet expired.
        XCTAssertFalse(center.expire(at: 2.9))
        XCTAssertEqual(center.toasts.count, 1)
        // At/after duration → expired.
        XCTAssertTrue(center.expire(at: 3.0))
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testExpiryBoundaryInclusive() {
        let (center, clock) = makeCenter()
        clock.t = 10
        let id = center.show("t", systemImage: "x", duration: 2.0)
        _ = id
        // Just before boundary: alive.
        XCTAssertFalse(center.toasts[0].hasExpired(at: 11.999))
        // Exactly at boundary: expired (>=).
        XCTAssertTrue(center.toasts[0].hasExpired(at: 12.0))
    }

    func testStickyToastNeverExpires() {
        let (center, clock) = makeCenter()
        clock.t = 0
        let id = center.showTranscribing()          // duration nil
        XCTAssertFalse(center.expire(at: 10_000))    // never auto-removed
        XCTAssertEqual(center.toasts.count, 1)
        // Explicit dismissal clears it.
        center.dismiss(id)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testStickyToastRemainingFractionIsAlwaysFull() {
        let (center, clock) = makeCenter()
        clock.t = 0
        center.showTranscribing()
        XCTAssertEqual(center.toasts[0].remainingFraction(at: 9_999), 1.0, accuracy: 1e-9)
    }

    // MARK: - remainingFraction ramp

    func testRemainingFractionDrainsLinearly() {
        let (center, clock) = makeCenter()
        clock.t = 0
        center.show("t", systemImage: "x", duration: 4.0)
        let toast = center.toasts[0]
        XCTAssertEqual(toast.remainingFraction(at: 0.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(toast.remainingFraction(at: 1.0), 0.75, accuracy: 1e-9)
        XCTAssertEqual(toast.remainingFraction(at: 2.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(toast.remainingFraction(at: 4.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(toast.remainingFraction(at: 5.0), 0.0, accuracy: 1e-9)   // clamped
    }

    // MARK: - Replace / dismiss (the Transcribing… → Pasted flow)

    func testReplaceKeepsStackPositionAndRestampsTime() {
        let (center, clock) = makeCenter()
        clock.t = 0
        center.show("first", systemImage: "1.circle", duration: 5.0)
        clock.t = 1
        let id = center.showTranscribing()          // second slot, sticky
        clock.t = 2
        center.show("third", systemImage: "3.circle", duration: 5.0)
        // Replace the sticky (middle) toast — it must keep its middle slot.
        clock.t = 3
        center.replace(id, with: Toast(message: "Pasted", systemImage: "checkmark",
                                       style: .success, duration: 1.6))
        XCTAssertEqual(center.toasts.map(\.message), ["first", "Pasted", "third"])
        // Restamped at t=3 → not expired until 3+1.6.
        XCTAssertFalse(center.toasts[1].hasExpired(at: 4.5))
        XCTAssertTrue(center.toasts[1].hasExpired(at: 4.7))
    }

    func testReplaceMissingIdFallsBackToShow() {
        let (center, _) = makeCenter()
        center.replace(UUID(), with: Toast(message: "orphan", systemImage: "x"))
        XCTAssertEqual(center.toasts.map(\.message), ["orphan"])
    }

    func testDismissMissingIdIsNoOp() {
        let (center, _) = makeCenter()
        center.show("keep", systemImage: "x")
        center.dismiss(UUID())
        XCTAssertEqual(center.toasts.map(\.message), ["keep"])
    }

    // MARK: - maxVisible cap

    func testCapDropsOldestAutoDismissible_keepsSticky() {
        let (center, _) = makeCenter(maxVisible: 2)
        let sticky = center.showTranscribing()      // sticky, slot 0
        center.show("a", systemImage: "x", duration: 3)
        center.show("b", systemImage: "x", duration: 3)   // exceeds cap of 2 → drop oldest auto ("a")
        XCTAssertEqual(center.toasts.count, 2)
        XCTAssertTrue(center.toasts.contains { $0.id == sticky })   // sticky preserved
        XCTAssertEqual(center.toasts.map(\.message), ["Transcribing…", "b"])
    }

    // MARK: - nextExpiry

    func testNextExpiryIsSoonestAutoToast() {
        let (center, clock) = makeCenter()
        clock.t = 0
        center.show("slow", systemImage: "x", duration: 5.0)   // expiry 5
        center.show("fast", systemImage: "x", duration: 2.0)   // expiry 2
        center.showTranscribing()                              // sticky (ignored)
        XCTAssertEqual(try XCTUnwrap(center.nextExpiry()), 2.0, accuracy: 1e-9)
    }

    func testNextExpiryNilWhenOnlyStickyOrEmpty() {
        let (center, _) = makeCenter()
        XCTAssertNil(center.nextExpiry())
        center.showTranscribing()
        XCTAssertNil(center.nextExpiry())
    }

    // MARK: - Semantic helpers

    func testShowMicrophoneUsesNameOrFallback() {
        let (center, _) = makeCenter()
        center.showMicrophone("MacBook Pro Microphone")
        XCTAssertEqual(center.toasts.last?.message, "MacBook Pro Microphone")
        center.showMicrophone("")
        XCTAssertEqual(center.toasts.last?.message, "Default microphone")
    }

    func testSemanticHelpersHaveExpectedStyles() {
        let (center, _) = makeCenter()
        center.showTranscribing()
        center.showPasted()
        center.showTranscribeFailed()
        XCTAssertEqual(center.toasts[0].style, .info)
        XCTAssertNil(center.toasts[0].duration)          // sticky
        XCTAssertEqual(center.toasts[1].style, .success)
        XCTAssertEqual(center.toasts[2].style, .failure)
    }
}
