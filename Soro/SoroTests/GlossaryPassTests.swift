import XCTest
@testable import Soro

// MARK: - GlossaryPass unit tests

final class GlossaryPassTests: XCTestCase {

    // MARK: buildInitialPrompt

    func testBuildInitialPromptEmpty() {
        XCTAssertEqual(GlossaryPass.buildInitialPrompt(from: []), "")
    }

    func testBuildInitialPromptSingleTerm() {
        let result = GlossaryPass.buildInitialPrompt(from: ["Supabase"])
        XCTAssertEqual(result, "Supabase")
    }

    func testBuildInitialPromptMultipleTermsJoinedByComma() {
        let result = GlossaryPass.buildInitialPrompt(from: ["Supabase", "Y Combinator", "SwiftUI"])
        XCTAssertEqual(result, "Supabase, Y Combinator, SwiftUI")
    }

    func testBuildInitialPromptCapsAt800Chars() {
        // Create terms that together would exceed 800 chars. The function must truncate.
        // Each term is 50 chars; 800 / (50+2) ≈ 15 terms fit, 16th should be cut.
        let term = String(repeating: "A", count: 50)
        let terms = Array(repeating: term, count: 20)
        let result = GlossaryPass.buildInitialPrompt(from: terms)
        XCTAssertLessThanOrEqual(result.count, 800,
            "Initial prompt must not exceed 800-character budget")
        // At least one term must appear.
        XCTAssertTrue(result.contains(term))
    }

    func testBuildInitialPromptExactlyAtBudget() {
        // A single 800-char term must be included (it exactly fills the budget).
        let term = String(repeating: "B", count: 800)
        let result = GlossaryPass.buildInitialPrompt(from: [term])
        XCTAssertEqual(result, term)
        XCTAssertEqual(result.count, 800)
    }

    func testBuildInitialPromptTermOverBudgetTruncates() {
        // A term that alone exceeds the 800-char budget causes the loop to stop (greedy approach).
        // Neither the oversized term nor any subsequent terms are emitted.
        let bigTerm = String(repeating: "C", count: 801)
        let smallTerm = "Swift"
        let result = GlossaryPass.buildInitialPrompt(from: [bigTerm, smallTerm])
        // bigTerm (801 chars) > budget (800) → loop stops immediately, result is empty.
        XCTAssertEqual(result, "",
            "When the first term exceeds budget the output should be empty (greedy stop)")
        XCTAssertFalse(result.contains(bigTerm))
        XCTAssertFalse(result.contains(smallTerm),
            "Terms after an oversized term are not reached in the greedy approach")
    }

    func testBuildInitialPromptSmallTermAfterFittingLargeTermsStops() {
        // The first term at exactly 800 chars fills the budget; no subsequent term fits.
        let exactTerm = String(repeating: "D", count: 800)
        let extra = "Extra"
        let result = GlossaryPass.buildInitialPrompt(from: [exactTerm, extra])
        XCTAssertEqual(result, exactTerm, "Exactly-fitting term should be included")
        XCTAssertFalse(result.contains(extra), "Subsequent terms must not push over budget")
    }

    // MARK: caseCorrect — basic substitution

    func testCaseCorrectNoTerms() {
        let text = "hello world"
        XCTAssertEqual(GlossaryPass.caseCorrect(text: text, terms: []), text)
    }

    func testCaseCorrectExactMatch() {
        let result = GlossaryPass.caseCorrect(text: "I use supabase daily", terms: ["Supabase"])
        XCTAssertEqual(result, "I use Supabase daily")
    }

    func testCaseCorrectUppercaseInput() {
        let result = GlossaryPass.caseCorrect(text: "I use SUPABASE daily", terms: ["Supabase"])
        XCTAssertEqual(result, "I use Supabase daily")
    }

    func testCaseCorrectMixedCaseInput() {
        let result = GlossaryPass.caseCorrect(text: "suPaBase is great", terms: ["Supabase"])
        XCTAssertEqual(result, "Supabase is great")
    }

    func testCaseCorrectMultipleTerms() {
        let text = "use SWIFTUI and xcode together"
        let result = GlossaryPass.caseCorrect(text: text, terms: ["SwiftUI", "Xcode"])
        XCTAssertEqual(result, "use SwiftUI and Xcode together")
    }

    // MARK: caseCorrect — word-boundary enforcement (no mid-word replacement)

    func testCaseCorrectNoMidWordReplacement() {
        // "Supabase" must not alter "Supabasement" (contrived but tests the boundary).
        let text = "Supabasement is not Supabase"
        let result = GlossaryPass.caseCorrect(text: text, terms: ["Supabase"])
        // "Supabasement" starts with Supabase but should not be changed.
        XCTAssertTrue(result.contains("Supabasement"),
            "Mid-word match must not be replaced")
        XCTAssertTrue(result.hasSuffix("Supabase"),
            "Standalone word must still be corrected")
    }

    func testCaseCorrectNoPrefixMatchOnly() {
        // Term "iOS" must not match inside "iOS13" (digit follows letter).
        let text = "use ios on ios13 devices"
        let result = GlossaryPass.caseCorrect(text: text, terms: ["iOS"])
        // "ios13" should remain unchanged (digit adjacent), standalone "ios" corrected.
        XCTAssertTrue(result.contains("iOS on"),
            "Standalone 'ios' should be corrected to 'iOS'")
        XCTAssertTrue(result.contains("ios13"),
            "'ios13' must not be altered — digit makes it a different token")
    }

    func testCaseCorrectTermAtStartOfString() {
        let result = GlossaryPass.caseCorrect(text: "xcode is great", terms: ["Xcode"])
        XCTAssertEqual(result, "Xcode is great")
    }

    func testCaseCorrectTermAtEndOfString() {
        let result = GlossaryPass.caseCorrect(text: "I love xcode", terms: ["Xcode"])
        XCTAssertEqual(result, "I love Xcode")
    }

    func testCaseCorrectTermWithPunctuation() {
        // Term adjacent to comma/period should still be corrected.
        let result = GlossaryPass.caseCorrect(text: "supabase, xcode.", terms: ["Supabase", "Xcode"])
        XCTAssertEqual(result, "Supabase, Xcode.")
    }

    func testCaseCorrectTermMultipleOccurrences() {
        let result = GlossaryPass.caseCorrect(text: "supabase and SUPABASE", terms: ["Supabase"])
        XCTAssertEqual(result, "Supabase and Supabase")
    }

    func testCaseCorrectMultiWordTerm() {
        // Multi-word glossary terms (e.g. "Y Combinator") should be corrected as a unit.
        let result = GlossaryPass.caseCorrect(text: "applied to y combinator yesterday",
                                               terms: ["Y Combinator"])
        XCTAssertEqual(result, "applied to Y Combinator yesterday")
    }
}

// MARK: - AutoDictionaryStore unit tests

@MainActor
final class AutoDictionaryStoreTests: XCTestCase {

    // MARK: observe / suggestions / dismiss

    func testSuggestsAfterThresholdMet() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        // Seen once — below threshold.
        store.observe(transcript: "I use Supabase at work")
        XCTAssertFalse(store.suggestions().contains("Supabase"),
            "Should not suggest before occurrence threshold is met")

        // Seen a second time — at threshold.
        store.observe(transcript: "Supabase is fast")
        XCTAssertTrue(store.suggestions().contains("Supabase"),
            "Should suggest after reaching threshold")
    }

    func testDismissRemovesFromSuggestions() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        store.observe(transcript: "Supabase is great")
        store.observe(transcript: "Supabase again")
        XCTAssertTrue(store.suggestions().contains("Supabase"))
        store.dismiss("Supabase")
        XCTAssertFalse(store.suggestions().contains("Supabase"))
    }

    func testDismissCaseInsensitive() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        store.observe(transcript: "Supabase rocks")
        store.observe(transcript: "Supabase again")
        store.dismiss("SUPABASE")  // dismiss with different casing
        XCTAssertFalse(store.suggestions().contains("Supabase"))
    }

    func testCommonWordsNotSuggested() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        // "The" is in the common-words list and should never become a candidate.
        store.observe(transcript: "The quick brown fox")
        store.observe(transcript: "The lazy dog")
        store.observe(transcript: "The end")
        XCTAssertFalse(store.suggestions().contains("The"),
            "Common sentence-start words must not be suggested")
    }

    func testGlossaryWordsExcludedFromSuggestions() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        // Inject a glossary checker that says "supabase" is already in glossary.
        store.isInGlossary = { word in word == "supabase" }

        store.observe(transcript: "Supabase is great")
        store.observe(transcript: "Supabase again")
        XCTAssertFalse(store.suggestions().contains("Supabase"),
            "Words already in the glossary must not appear in suggestions")
    }

    func testSuggestionsNotContaminatedByGlossaryAfterClosure() {
        // A word not in glossary is still suggested.
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        store.isInGlossary = { word in word == "supabase" }

        store.observe(transcript: "Supabase and WhisperKit rock")
        store.observe(transcript: "WhisperKit is fast")
        let sugg = store.suggestions()
        XCTAssertFalse(sugg.contains("Supabase"))
        XCTAssertTrue(sugg.contains("WhisperKit"))
    }

    func testSortedByDescendingFrequency() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        // Supabase × 3, WhisperKit × 2
        store.observe(transcript: "Supabase and WhisperKit")
        store.observe(transcript: "Supabase again")
        store.observe(transcript: "Supabase once more")
        store.observe(transcript: "WhisperKit is great")
        let sugg = store.suggestions()
        XCTAssertEqual(sugg.first, "Supabase", "Most frequent term should be first")
    }

    func testPersistsAndReloads() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        do {
            let store = AutoDictionaryStore(paths: paths)
            store.observe(transcript: "Supabase rocks")
            store.observe(transcript: "Supabase again")
        }
        // Reload from disk.
        let reloaded = AutoDictionaryStore(paths: paths)
        XCTAssertTrue(reloaded.suggestions().contains("Supabase"),
            "AutoDictionaryStore must persist and reload correctly")
    }

    func testErrorSentinelIgnored() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        store.observe(transcript: Transcript.errorSentinel)
        XCTAssertTrue(store.suggestions().isEmpty,
            "Error-sentinel transcript must not update any counts")
    }

    func testSingleLetterWordIgnored() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        // "A" and "I" are single-letter; must not be candidates.
        for _ in 0..<5 {
            store.observe(transcript: "A I U O E")
        }
        XCTAssertTrue(store.suggestions().isEmpty, "Single-letter words must never be suggested")
    }
}
