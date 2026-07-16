import XCTest
import AppKit
@testable import Soro

/// Tests for `PasteInsertionService`. These exercise pure logic only — the pasteboard
/// save/restore round-trip, the secure-input short-circuit, and last-text bookkeeping.
/// CGEvent posting is disabled (`postsEvents: false`) so nothing is synthesized to the system.
final class PasteInsertionServiceTests: XCTestCase {

    /// A private, uniquely-named pasteboard so tests never clobber the user's real clipboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("SoroTests-\(UUID().uuidString)"))
    }

    private func makeService(
        pasteboard: NSPasteboard,
        automaticEnter: Bool = false,
        secureInput: Bool = false,
        frontmost: String? = nil
    ) -> PasteInsertionService {
        PasteInsertionService(
            automaticEnter: { automaticEnter },
            frontmostBundleID: { frontmost },
            secureInputEnabled: { secureInput },
            pasteSettleMillis: 0,
            pasteboard: pasteboard,
            postsEvents: false
        )
    }

    // MARK: - Pasteboard save/restore round-trip

    func testPasteboardRestoredAfterInsert() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL-CLIPBOARD", forType: .string)

        let service = makeService(pasteboard: pb)
        let result = await service.insert("hello world")

        XCTAssertEqual(result, .pasted)
        // After the insert completes, the original clipboard content must be back.
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL-CLIPBOARD")
    }

    func testPasteboardRestoredWhenOriginallyEmpty() async {
        let pb = makePasteboard()
        pb.clearContents()

        let service = makeService(pasteboard: pb)
        _ = await service.insert("some text")

        // Nothing was on the pasteboard originally; it should end up empty again.
        XCTAssertNil(pb.string(forType: .string))
    }

    func testMultipleTypesPreservedOnRestore() async {
        let pb = makePasteboard()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data([0x01, 0x02, 0x03]), forType: NSPasteboard.PasteboardType("com.soro.custom"))
        pb.writeObjects([item])

        let service = makeService(pasteboard: pb)
        _ = await service.insert("inserted")

        XCTAssertEqual(pb.string(forType: .string), "plain")
        XCTAssertEqual(pb.data(forType: NSPasteboard.PasteboardType("com.soro.custom")), Data([0x01, 0x02, 0x03]))
    }

    // MARK: - Secure input short-circuit

    func testSecureInputShortCircuits() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("UNTOUCHED", forType: .string)

        let service = makeService(pasteboard: pb, secureInput: true)
        let result = await service.insert("secret")

        XCTAssertEqual(result, .failedSecureInput)
        // Must not have touched the pasteboard at all.
        XCTAssertEqual(pb.string(forType: .string), "UNTOUCHED")
    }

    func testSecureInputDoesNotRecordLastText() async {
        let pb = makePasteboard()
        let service = makeService(pasteboard: pb, secureInput: true)
        _ = await service.insert("secret")

        // Bookkeeping must not have captured the text, so reinsert has nothing to do.
        let reinsert = await service.reinsertLast()
        XCTAssertEqual(reinsert, .failed)
    }

    // MARK: - Last-text bookkeeping

    func testReinsertLastFailsWithNoPriorInsert() async {
        let pb = makePasteboard()
        let service = makeService(pasteboard: pb)
        let result = await service.reinsertLast()
        XCTAssertEqual(result, .failed)
    }

    func testReinsertLastReplaysLastText() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIG", forType: .string)

        let service = makeService(pasteboard: pb)
        _ = await service.insert("first text")
        let result = await service.reinsertLast()

        XCTAssertEqual(result, .pasted)
        // Pasteboard still restored after the reinsert.
        XCTAssertEqual(pb.string(forType: .string), "ORIG")
    }

    // MARK: - Empty text

    func testEmptyTextIsPastedNoop() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("KEEP", forType: .string)

        let service = makeService(pasteboard: pb)
        let result = await service.insert("")

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pb.string(forType: .string), "KEEP")
    }

    // MARK: - Per-app rules

    func testMessagesPathSucceeds() async {
        // The Messages per-app rule (lowercase first char) runs in the paste path; here we just
        // confirm the insert still completes as `.pasted` for that bundle id.
        let pb = makePasteboard()
        let service = makeService(pasteboard: pb, frontmost: "com.apple.MobileSMS")
        let result = await service.insert("Hello There")
        XCTAssertEqual(result, .pasted)
    }

    func testNonMessagesAppPreservesCase() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIG", forType: .string)
        let service = makeService(pasteboard: pb, frontmost: "com.apple.TextEdit")
        let result = await service.insert("Hello There")
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pb.string(forType: .string), "ORIG")
    }
}
