import XCTest
@testable import Soro

/// Unit tests for the pure stitching/dedup and silence-segmentation logic that
/// backs incremental (streaming) transcription. No mic, no model — all synthetic.
final class StreamingTranscriberTests: XCTestCase {

    // MARK: - TranscriptStitcher.stitch (no overlap = plain concat)

    func testStitchDisjointSegmentsJustConcatenates() {
        let out = TranscriptStitcher.stitch("hello world", "how are you")
        XCTAssertEqual(out, "hello world how are you")
    }

    func testStitchEmptyLeftReturnsRight() {
        XCTAssertEqual(TranscriptStitcher.stitch("", "second half"), "second half")
    }

    func testStitchEmptyRightReturnsLeft() {
        XCTAssertEqual(TranscriptStitcher.stitch("first half", "   "), "first half")
    }

    func testStitchBothEmpty() {
        XCTAssertEqual(TranscriptStitcher.stitch("", ""), "")
    }

    // MARK: - TranscriptStitcher.stitch (boundary overlap dedup)

    func testStitchDropsSingleDuplicatedBoundaryWord() {
        // "…the meeting" | "meeting is at noon" → drop the repeated "meeting".
        let out = TranscriptStitcher.stitch("let's schedule the meeting",
                                            "meeting is at noon")
        XCTAssertEqual(out, "let's schedule the meeting is at noon")
    }

    func testStitchDropsMultiWordOverlap() {
        let out = TranscriptStitcher.stitch("please send it to the team today",
                                            "the team today so they can review")
        XCTAssertEqual(out, "please send it to the team today so they can review")
    }

    func testStitchOverlapIgnoresCaseAndPunctuation() {
        // Boundary word repeats but with different case + trailing comma.
        let out = TranscriptStitcher.stitch("we walked into the Room,",
                                            "room and sat down")
        XCTAssertEqual(out, "we walked into the Room, and sat down")
    }

    func testStitchFullRightIsSubsumedByLeftTail() {
        // right is entirely a repeat of left's tail → nothing new appended.
        let out = TranscriptStitcher.stitch("alpha beta gamma", "beta gamma")
        XCTAssertEqual(out, "alpha beta gamma")
    }

    func testStitchDoesNotOverDedupBeyondMaxOverlap() {
        // A 7-word repeat with maxOverlap 6 keeps the un-matched first word.
        let left = "a b c d e f g"
        let right = "a b c d e f g h"
        let out = TranscriptStitcher.stitch(left, right, maxOverlapWords: 6)
        // Longest suffix/prefix match within 6 words is "b c d e f g"; the leading
        // "a" of right is preserved.
        XCTAssertEqual(out, "a b c d e f g a b c d e f g h")
    }

    func testStitchAvoidsFalseOverlapOnCommonSmallWords() {
        // A single trivially-repeated "the" IS deduped (by design, longest match).
        let out = TranscriptStitcher.stitch("I saw the", "the dog run")
        XCTAssertEqual(out, "I saw the dog run")
    }

    // MARK: - TranscriptStitcher.join

    func testJoinFiltersEmptySegments() {
        let out = TranscriptStitcher.join(["one two", "", "   ", "three four"])
        XCTAssertEqual(out, "one two three four")
    }

    func testJoinSingleSegment() {
        XCTAssertEqual(TranscriptStitcher.join(["just one"]), "just one")
    }

    func testJoinEmptyList() {
        XCTAssertEqual(TranscriptStitcher.join([]), "")
    }

    func testJoinStitchesOverlapAcrossThreeSegments() {
        let out = TranscriptStitcher.join([
            "the quick brown fox",
            "brown fox jumps over",
            "over the lazy dog"
        ])
        XCTAssertEqual(out, "the quick brown fox jumps over the lazy dog")
    }

    // MARK: - SilenceSegmenter.cutPoint

    /// Build a buffer of `speechSecs` loud audio + `silenceSecs` quiet audio at 16k.
    private func makeBuffer(speechSecs: Double, silenceSecs: Double,
                            amplitude: Float = 0.3) -> [Float] {
        let rate = 16_000
        let speechN = Int(speechSecs * Double(rate))
        let silenceN = Int(silenceSecs * Double(rate))
        var out = [Float](repeating: 0, count: speechN + silenceN)
        for i in 0..<speechN {
            // Non-zero alternating signal so RMS is well above the silence floor.
            out[i] = (i % 2 == 0) ? amplitude : -amplitude
        }
        // silence region stays ~0 (leave as zeros)
        return out
    }

    func testCutPointNilWhenBufferTooShort() {
        // Only 2 s total — below the 6 s minChunk default.
        let buf = makeBuffer(speechSecs: 2, silenceSecs: 0)
        XCTAssertNil(SilenceSegmenter.cutPoint(in: buf))
    }

    func testCutPointNilWhenNoSilenceGap() {
        // 8 s of continuous speech, no quiet run to cut on.
        let buf = makeBuffer(speechSecs: 8, silenceSecs: 0)
        XCTAssertNil(SilenceSegmenter.cutPoint(in: buf))
    }

    func testCutPointFindsTrailingSilence() {
        // 7 s speech then 1 s silence → cut should land inside the silence region.
        let buf = makeBuffer(speechSecs: 7, silenceSecs: 1)
        let cut = SilenceSegmenter.cutPoint(in: buf)
        XCTAssertNotNil(cut)
        if let cut {
            // Cut is at/after the speech end (7 s) and before the buffer end.
            XCTAssertGreaterThanOrEqual(cut, 16_000 * 7)
            XCTAssertLessThanOrEqual(cut, buf.count)
        }
    }

    func testCutPointRespectsMinLead() {
        // Silence starts almost immediately (0.2 s speech) — below minLead (1 s),
        // even though total length passes minChunk (pad tail speech to reach 6 s).
        var buf = makeBuffer(speechSecs: 0.2, silenceSecs: 0.5)
        buf.append(contentsOf: makeBuffer(speechSecs: 6, silenceSecs: 0))
        let cut = SilenceSegmenter.cutPoint(in: buf)
        // The early silence gap is too early to cut on; the later continuous speech
        // offers no gap → nil.
        XCTAssertNil(cut)
    }

    func testCutPointMidSilenceIsWithinQuietRegion() {
        let speechSecs = 6.0
        let buf = makeBuffer(speechSecs: speechSecs, silenceSecs: 2)
        guard let cut = SilenceSegmenter.cutPoint(in: buf) else {
            return XCTFail("expected a cut point")
        }
        // Verify the cut sample actually sits in the silent tail (value ≈ 0).
        XCTAssertLessThan(abs(buf[cut]), 0.001)
    }
}
