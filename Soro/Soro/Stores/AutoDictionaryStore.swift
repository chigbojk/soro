import Foundation
import Combine

/// JSON-backed store for `Preferences/auto_dictionary_cache.json`.
///
/// Tracks word frequency across all transcripts and surfaces *proper nouns and jargon* as
/// suggested dictionary terms (§3c). Common English words are excluded from suggestions even if
/// they happen to be capitalized (sentence-start false positives).
///
/// ## Heuristics
///
/// **Tracking** (`observe`): every token is counted (lowercased key) so occurrence data is as
/// rich as possible. Nothing is filtered out at the tracking stage.
///
/// **Suggestion** (`suggestions`): returns only tokens that pass *all* of the following:
///   1. `occurrenceCount >= suggestionThreshold` (default 2).
///   2. Not in the dismissed set.
///   3. Not already in the glossary (via injected `isInGlossary`).
///   4. Passes `looksLikeJargonOrProperNoun(_:)` — i.e. the *stored* form of the word is:
///      - ALL-CAPS acronym (≥ 2 chars, all uppercase letters),
///      - camelCase (contains an uppercase letter that is NOT the first character),
///      - snake_case (contains an underscore and at least one letter),
///      - Capitalized mid-token initial **and** not a stopword/common-English word.
@MainActor
final class AutoDictionaryStore: ObservableObject {
    /// keyed by lowercased word → entry (matches the JSON map shape in §6).
    @Published private(set) var cache: [String: AutoDictionaryEntry]

    /// Words the user explicitly dismissed — never re-suggested (in-memory; resets on relaunch).
    private var dismissed: Set<String> = []

    /// A term must recur at least this many times before it is suggested.
    private let suggestionThreshold = 2

    private let paths: AppPaths

    /// Optional closure injected so suggestions can exclude words already in the glossary.
    /// Returns `true` when the given lowercased word is already a glossary term.
    var isInGlossary: ((String) -> Bool)?

    init(paths: AppPaths = .live) {
        self.paths = paths
        self.cache = JSONFile.read([String: AutoDictionaryEntry].self,
                                   from: paths.autoDictionaryFile) ?? [:]
    }

    func save() {
        try? JSONFile.write(cache, to: paths.autoDictionaryFile)
    }

    // MARK: - Pipeline API (§3c)

    /// Observes a completed transcript, incrementing frequency counts for all non-trivial tokens.
    ///
    /// Tokenizes on non-letter, non-apostrophe, non-underscore boundaries and records every
    /// token longer than one character.  Filtering happens at *suggestion* time, not here, so
    /// jargon that initially appears lowercased can still accumulate counts.
    func observe(transcript: String) {
        guard transcript != Transcript.errorSentinel else { return }
        let now = Date().timeIntervalSinceReferenceDate
        // Split on characters that are neither letters, apostrophes, nor underscores.
        // This preserves snake_case and contractions as single tokens.
        let words = transcript.split { !$0.isLetter && $0 != "'" && $0 != "_" }.map(String.init)
        for word in words where word.count > 1 {
            let key = word.lowercased()
            if var existing = cache[key] {
                // Prefer storing the most-recently-seen form that looks like jargon so the
                // displayed suggestion word keeps its casing (e.g. "Supabase" wins over "supabase").
                if looksLikeJargonOrProperNoun(word) {
                    existing.word = word
                }
                existing.occurrenceCount += 1
                existing.lastSeen = now
                cache[key] = existing
            } else {
                cache[key] = AutoDictionaryEntry(
                    word: word, firstSeen: now, lastSeen: now, occurrenceCount: 1)
            }
        }
        save()
    }

    /// Words seen `suggestionThreshold` or more times that look like proper nouns or jargon,
    /// not dismissed, and not already in the glossary.
    /// Sorted by descending frequency so the most-used terms surface first.
    func suggestions() -> [String] {
        cache.values
            .filter { entry in
                guard entry.occurrenceCount >= suggestionThreshold else { return false }
                let key = entry.word.lowercased()
                if dismissed.contains(key) { return false }
                if let check = isInGlossary, check(key) { return false }
                // Only surface tokens that truly look like names or jargon.
                return looksLikeJargonOrProperNoun(entry.word)
            }
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
            .map { $0.word }
    }

    /// Permanently dismisses a word from future suggestions (session-scoped).
    func dismiss(_ word: String) {
        dismissed.insert(word.lowercased())
        objectWillChange.send()
    }

    // MARK: - Jargon / proper-noun heuristic

    /// Returns `true` when a token is likely a proper noun, brand name, acronym, or technical term.
    ///
    /// Accepted forms:
    /// - **ALL-CAPS acronym**: ≥ 2 letter characters, every letter is uppercase
    ///   (e.g. "API", "JSON", "WWDC").
    /// - **camelCase**: contains an uppercase letter that is *not* the first character
    ///   (e.g. "SwiftUI", "iPhone", "openAI").
    /// - **snake_case**: contains an underscore and at least one letter
    ///   (e.g. "my_var", "AUTH_TOKEN").
    /// - **Capitalized proper noun**: starts with an uppercase letter, ≥ 2 *letter* characters,
    ///   the word (letters only) is not a stopword, and it has no apostrophe
    ///   (apostrophes indicate contractions like "It's" which are never proper nouns).
    ///
    /// All conditions require total length ≥ 2.
    func looksLikeJargonOrProperNoun(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }

        // snake_case — underscores indicate a technical identifier.
        if word.contains("_") && word.contains(where: { $0.isLetter }) {
            return true
        }

        let letters = word.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }

        // ALL-CAPS acronym — every letter character is uppercase, at least 2 letters.
        if letters.allSatisfy({ $0.isUppercase }) {
            return true
        }

        // camelCase — an uppercase letter somewhere after the first character.
        let afterFirst = word.dropFirst()
        if afterFirst.contains(where: { $0.isUppercase }) {
            return true
        }

        // Capitalized proper noun — starts uppercase, no apostrophe (contractions are not proper
        // nouns), and the lowercased word (letters only) is not a known common English word.
        if let first = word.first, first.isUppercase, !word.contains("'") {
            return !Self.commonWords.contains(word.lowercased())
        }

        return false
    }

    // MARK: - Common-words exclusion set

    /// High-frequency English words that are capitalized at sentence start but are almost never
    /// proper nouns or brands. Kept comprehensive to avoid flooding suggestions.
    static let commonWords: Set<String> = [
        // Articles, conjunctions, prepositions
        "the", "a", "an", "and", "or", "but", "nor", "so", "yet", "for",
        "at", "in", "on", "by", "to", "of", "from", "with", "about", "into",
        "through", "during", "before", "after", "above", "below", "between", "among",
        "against", "along", "around", "beyond", "despite", "except", "inside",
        "outside", "since", "toward", "under", "until", "upon", "within", "without",

        // Pronouns
        "it", "its", "this", "that", "these", "those",
        "he", "she", "we", "they", "you", "i",
        "his", "her", "our", "their", "your", "my",
        "him", "them", "me", "us", "who", "whom", "whose",
        "what", "which", "where", "when", "how",

        // Auxiliaries and common verbs
        "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "have", "has", "had",
        "will", "would", "could", "should", "may", "might", "must", "shall", "can",
        "not", "no", "yes",
        "say", "said", "get", "got", "go", "went", "come", "came", "take", "took",
        "see", "saw", "know", "knew", "think", "thought", "want", "use", "make",
        "made", "give", "find", "tell", "feel", "keep", "let", "put", "seem", "leave",
        "turn", "start", "show", "play", "run", "move", "live", "call", "try", "ask",
        "need", "look", "mean", "become", "bring", "happen", "write", "provide",
        "sit", "stand", "hear", "hold", "appear", "change", "set", "understand",

        // Adverbs and common adjectives
        "if", "then", "else", "when", "while", "as", "because", "since", "until",
        "up", "down", "out", "off", "over", "under", "again", "further", "also",
        "just", "only", "even", "both", "each", "every", "all", "any", "few",
        "more", "most", "other", "some", "such", "than", "too", "very",
        "here", "there", "well", "now", "still", "already", "however", "though",
        "although", "whether", "either", "neither", "else", "perhaps", "maybe",
        "really", "quite", "rather", "simply", "certainly", "probably", "actually",
        "basically", "literally", "obviously", "definitely", "specifically",
        "especially", "particularly", "generally", "usually", "often", "always",
        "never", "sometimes", "recently", "currently", "already", "finally",
        "quickly", "easily", "simply", "clearly", "directly", "roughly",

        // Numbers and ordinals
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "first", "second", "third", "fourth", "fifth",
        "hundred", "thousand", "million",

        // Common nouns / adjectives that frequently appear capitalized
        "new", "old", "good", "great", "last", "next", "same", "own", "right", "left",
        "high", "low", "large", "small", "long", "short", "little", "big", "real",
        "hard", "easy", "early", "late", "public", "private", "free", "full", "open",
        "able", "true", "false", "sure", "ready", "happy", "different", "important",
        "possible", "available", "certain", "clear", "close", "common", "deep",
        "example", "fact", "information", "point", "question", "reason", "result",
        "system", "world", "part", "place", "case", "week", "company", "program",
        "problem", "person", "people", "group", "number", "hand", "side", "home",
        "time", "way", "day", "man", "woman", "year", "back", "life", "thing",
        "kind", "type", "lot", "line", "name", "word", "form", "order", "area",
        "end", "plan", "state", "job", "note", "term",

        // Sentence starters / connectors
        "check", "look", "well", "so", "okay", "ok", "sure", "right", "yeah",
        "yes", "no", "hey", "hi", "hello", "please", "thanks", "thank",
        "sorry", "actually", "basically", "anyway", "however", "therefore",
        "finally", "additionally", "furthermore", "meanwhile",

        // Fillers / disfluencies (often transcribed capitalized at start)
        "um", "uh", "er", "oh", "ah", "hmm", "like", "just", "really"
    ]
}
