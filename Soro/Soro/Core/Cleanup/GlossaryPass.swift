import Foundation

/// Glossary-pass utilities for the dictation pipeline (brief §3c).
///
/// Two responsibilities:
/// 1. **Whisper biasing** — build an `initial_prompt` string from enabled glossary terms so whisper
///    recognises names/jargon correctly. Capped at ~200 tokens (≈ 800 chars as a safe proxy).
/// 2. **Case correction** — after transcription, force the exact casing of each glossary term
///    wherever it appears in the text, using word-boundary-aware replacement.
///    Only whole-word, case-insensitive matches are replaced; substrings are left alone.
enum GlossaryPass {

    // MARK: - Whisper initial_prompt

    /// Builds a comma-joined vocabulary-bias string for Whisper's `initial_prompt` parameter.
    ///
    /// Whisper uses the initial_prompt to prime its language model, so listing known terms helps
    /// it recognise unusual names, brands, and acronyms. The prompt is capped at ~200 tokens
    /// (using a character budget of 800 as a safe approximation — whisper tokenises roughly
    /// 4 chars/token for English proper nouns).
    ///
    /// - Parameter enabledTerms: the output of `GlossaryStore.enabledTerms()`.
    /// - Returns: a comma-separated string, or an empty string if `enabledTerms` is empty.
    static func buildInitialPrompt(from enabledTerms: [String]) -> String {
        guard !enabledTerms.isEmpty else { return "" }

        // Character budget: ~200 whisper tokens × ~4 chars/token = 800 chars.
        let charBudget = 800

        var parts: [String] = []
        var used = 0

        for term in enabledTerms {
            // Account for separator ", " (2 chars) after the first term.
            let needed = term.count + (parts.isEmpty ? 0 : 2)
            if used + needed > charBudget { break }
            parts.append(term)
            used += needed
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Case correction

    /// Forces exact casing of each glossary term on case-insensitive whole-word matches.
    ///
    /// This corrects whisper's tendency to mis-capitalise known terms (e.g. "supabase" → "Supabase").
    /// Only whole-word matches are replaced — a term will never alter the interior of a longer word.
    ///
    /// - Parameters:
    ///   - text:  the raw transcript text.
    ///   - terms: the list of terms whose casing must be preserved (from `GlossaryStore.enabledTerms()`).
    /// - Returns: the text with exact-casing applied for all matched terms.
    static func caseCorrect(text: String, terms: [String]) -> String {
        guard !terms.isEmpty else { return text }

        var result = text

        for term in terms {
            guard !term.isEmpty else { continue }

            // Build a regex that matches the term at word boundaries, case-insensitively.
            // We escape the term so special regex characters in glossary entries are treated literally.
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"

            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: .caseInsensitive) else {
                continue
            }

            let nsResult = result as NSString
            let range = NSRange(location: 0, length: nsResult.length)

            // Replace each match with the correctly-cased term.
            // Work backwards through matches so offsets remain valid.
            let matches = regex.matches(in: result, options: [], range: range)
            for match in matches.reversed() {
                result = (result as NSString)
                    .replacingCharacters(in: match.range, with: term)
            }
        }

        return result
    }
}
