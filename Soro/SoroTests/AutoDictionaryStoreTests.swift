import XCTest
@testable import Soro

/// Unit tests for the improved `AutoDictionaryStore` suggestion filtering logic.
///
/// These tests focus on the new `looksLikeJargonOrProperNoun` heuristic and the
/// end-to-end suggestion pipeline (proper nouns / jargon IN, common words OUT,
/// glossary-excluded, dismissed-excluded, threshold gate).
///
/// Existing baseline tests live in `GlossaryPassTests.swift` (class `AutoDictionaryStoreTests`).
@MainActor
final class AutoDictionarySuggestionFilterTests: XCTestCase {

    // MARK: - looksLikeJargonOrProperNoun

    /// Capitalized proper nouns that start uppercase and are not stopwords should be accepted.
    func testProperNounCapitalized() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("Supabase"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("Jordan"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("Anthropic"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("WhisperKit"))
    }

    /// ALL-CAPS acronyms (≥ 2 uppercase letters) should be accepted.
    func testAllCapsAcronym() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("API"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("JSON"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("WWDC"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("URL"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("SQL"))
    }

    /// camelCase tokens (uppercase letter after the first character) should be accepted.
    func testCamelCase() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("SwiftUI"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("iPhone"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("openAI"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("camelCase"))
    }

    /// snake_case tokens should be accepted.
    func testSnakeCase() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("my_var"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("AUTH_TOKEN"))
        XCTAssertTrue(store.looksLikeJargonOrProperNoun("user_id"))
    }

    /// Very short tokens (1 character) should be rejected.
    func testSingleCharacterRejected() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("A"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("I"))
    }

    /// Common English words should be rejected even when capitalized.
    func testCommonWordsRejected() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        // Sentence-start false positives (in commonWords set)
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("The"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("It"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("Check"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("He"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("She"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("We"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("This"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("That"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("So"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("But"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("And"))
    }

    /// Contractions (tokens containing an apostrophe) are rejected because they are
    /// never proper nouns regardless of casing.
    func testContractionsRejected() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("It's"),
                       "Contraction with apostrophe must be rejected")
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("Don't"),
                       "Contraction with apostrophe must be rejected")
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("I'm"),
                       "Contraction with apostrophe must be rejected")
    }

    /// Fully-lowercase common words should be rejected.
    func testLowercaseCommonWordsRejected() {
        let store = AutoDictionaryStore(paths: makeTempPaths())
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("the"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("and"))
        XCTAssertFalse(store.looksLikeJargonOrProperNoun("check"))
    }

    // MARK: - suggestions() threshold

    /// A proper-noun token seen fewer than threshold times should NOT appear in suggestions.
    func testSuggestionThresholdGate() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        // Observe once — below threshold (2)
        store.observe(transcript: "Using Supabase today")
        XCTAssertFalse(store.suggestions().contains("Supabase"),
                       "Should not suggest a word seen only once")

        // Observe a second time — at threshold
        store.observe(transcript: "Supabase scales well")
        XCTAssertTrue(store.suggestions().contains("Supabase"),
                      "Should suggest a word seen exactly threshold times")
    }

    // MARK: - suggestions() proper nouns / jargon IN, common words OUT

    /// Common words should never appear in suggestions regardless of frequency.
    func testCommonWordsNeverSuggested() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        // Repeat common words many times
        for _ in 0..<5 {
            store.observe(transcript: "Check the situation. It's important. The result is clear.")
        }

        let suggestions = store.suggestions()
        XCTAssertFalse(suggestions.contains("Check"), "\"Check\" is a common word")
        XCTAssertFalse(suggestions.contains("The"),   "\"The\" is an article")
        // "It's" is a contraction — our heuristic rejects tokens containing apostrophes
        // (they are never proper nouns); verify it is absent.
        XCTAssertFalse(suggestions.contains("It's"), "Contraction \"It's\" must not be suggested")
    }

    /// Proper nouns appearing at threshold should be suggested.
    func testProperNounsAreSuggested() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        store.observe(transcript: "Anthropic released Claude.")
        store.observe(transcript: "Claude is made by Anthropic.")

        let suggestions = store.suggestions()
        XCTAssertTrue(suggestions.contains("Anthropic"), "\"Anthropic\" is a proper noun brand name")
        XCTAssertTrue(suggestions.contains("Claude"),    "\"Claude\" is a proper noun")
    }

    /// camelCase jargon appearing at threshold should be suggested.
    func testCamelCaseJargonSuggested() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        store.observe(transcript: "Use SwiftUI for the view layer.")
        store.observe(transcript: "SwiftUI works with previews.")

        XCTAssertTrue(store.suggestions().contains("SwiftUI"))
    }

    /// ALL-CAPS acronyms at threshold should be suggested.
    func testAcronymsSuggested() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        store.observe(transcript: "The API returns JSON results.")
        store.observe(transcript: "POST to the API endpoint with JSON payload.")

        let suggestions = store.suggestions()
        XCTAssertTrue(suggestions.contains("API"),  "Acronym API should be suggested")
        XCTAssertTrue(suggestions.contains("JSON"), "Acronym JSON should be suggested")
    }

    // MARK: - suggestions() exclude glossary terms

    /// Words already present in the glossary (via `isInGlossary`) should not be suggested.
    func testGlossaryTermsExcludedFromSuggestions() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        store.isInGlossary = { word in word == "supabase" }

        store.observe(transcript: "Supabase is fast.")
        store.observe(transcript: "Supabase is reliable.")

        XCTAssertFalse(store.suggestions().contains("Supabase"),
                       "Already-glossary term should be excluded from suggestions")
    }

    /// A word NOT in the glossary should still be suggested.
    func testNonGlossaryTermSuggested() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        store.isInGlossary = { word in word == "firebase" }

        store.observe(transcript: "Supabase is fast.")
        store.observe(transcript: "Supabase is reliable.")

        XCTAssertTrue(store.suggestions().contains("Supabase"),
                      "Non-glossary term should be suggested")
    }

    // MARK: - suggestions() dismiss

    /// Dismissed words should not re-appear in suggestions.
    func testDismissedWordExcluded() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        store.observe(transcript: "Anthropic is the maker.")
        store.observe(transcript: "Anthropic released Claude.")
        XCTAssertTrue(store.suggestions().contains("Anthropic"))

        store.dismiss("Anthropic")
        XCTAssertFalse(store.suggestions().contains("Anthropic"),
                       "Dismissed word should not appear in suggestions")
    }

    /// Dismiss is case-insensitive.
    func testDismissCaseInsensitive() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        store.observe(transcript: "Anthropic released Claude.")
        store.observe(transcript: "Anthropic is great.")

        // Dismiss with different casing
        store.dismiss("anthropic")
        XCTAssertFalse(store.suggestions().contains("Anthropic"),
                       "Dismiss should match case-insensitively")
    }

    // MARK: - suggestions() sort order

    /// Suggestions are sorted by descending frequency.
    func testSuggestionsOrderedByFrequency() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        // Supabase × 4, Claude × 2
        for _ in 0..<4 { store.observe(transcript: "Supabase benchmark") }
        for _ in 0..<2 { store.observe(transcript: "Claude responds") }

        let suggestions = store.suggestions()
        guard let supaIdx = suggestions.firstIndex(of: "Supabase"),
              let claudeIdx = suggestions.firstIndex(of: "Claude") else {
            XCTFail("Expected both Supabase and Claude in suggestions")
            return
        }
        XCTAssertLessThan(supaIdx, claudeIdx,
                          "More-frequent term (Supabase) should come before less-frequent (Claude)")
    }

    // MARK: - observe: mixed transcript

    /// A transcript mixing proper nouns with common words should track both,
    /// but only proper nouns surface as suggestions.
    func testMixedTranscriptOnlySurfacesProperNouns() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        let transcript = "Check that Supabase is running. It's important."
        store.observe(transcript: transcript)
        store.observe(transcript: transcript)

        let suggestions = store.suggestions()
        XCTAssertTrue(suggestions.contains("Supabase"))
        XCTAssertFalse(suggestions.contains("Check"), "\"Check\" must not appear")
        XCTAssertFalse(suggestions.contains("It's"),  "\"It's\" must not appear")
        XCTAssertFalse(suggestions.contains("That"),  "\"That\" must not appear")
    }

    // MARK: - observe: error sentinel ignored

    func testErrorSentinelNotObserved() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        store.observe(transcript: Transcript.errorSentinel)
        XCTAssertTrue(store.cache.isEmpty, "Error sentinel should not be tracked")
    }
}
