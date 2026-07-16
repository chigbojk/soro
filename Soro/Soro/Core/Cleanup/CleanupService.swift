import Foundation

/// Everything the cleanup pass needs about the current context (brief §3d/§5).
struct CleanupContext: Sendable {
    let appName: String
    let bundleId: String
    let context: DictationContext
    let messagingStyle: String
    let scribeStyle: String
    let personalTweak: String
    let glossaryTerms: [String]
    let styleSamples: [String]        // 0–3 recent accepted outputs
    let isCodeEditor: Bool
}

/// Ollama cleanup + style pass. NEVER throws to the caller: on any failure or
/// timeout it falls back to the input text (brief §3d).
protocol CleanupService: AnyObject {
    func isAvailable() async -> Bool
    /// Returns (text, wasCleaned). timeout ~4s → (input, false).
    func cleanup(_ raw: String, context: CleanupContext) async -> (text: String, wasCleaned: Bool)
}

/// M1 stub — always unavailable, passes raw text through unchanged.
final class StubCleanupService: CleanupService {
    func isAvailable() async -> Bool { false }

    func cleanup(_ raw: String, context: CleanupContext) async -> (text: String, wasCleaned: Bool) {
        (raw, false)
    }
}

/// M7 real implementation. Sends the glossary-corrected transcript to a local
/// Ollama model with the Appendix-B system prompt and returns cleaned text.
///
/// Contract guarantees (brief §3d):
/// - Never throws. On unavailable / timeout / any error → `(raw, false)`.
/// - Enforces a hard request timeout (the client's 4s) with raw fallback.
/// - Defensively strips model preamble, surrounding quotes, and code fences.
/// - Empty or whitespace-only input short-circuits to `(raw, false)`.
final class OllamaCleanupService: CleanupService {
    private let client: OllamaClient
    private let promptBuilder: PromptBuilder
    /// Optional live model selection (reads `prefs.ollamaModel`) so switching the
    /// cleanup model in Settings takes effect without an app restart.
    private let modelOverride: (() -> String)?

    init(client: OllamaClient = OllamaClient(),
         promptBuilder: PromptBuilder = PromptBuilder(),
         modelOverride: (() -> String)? = nil) {
        self.client = client
        self.promptBuilder = promptBuilder
        self.modelOverride = modelOverride
    }

    /// The client to use for a call — a copy with the live-selected model applied.
    private var activeClient: OllamaClient {
        guard let m = modelOverride?(), !m.isEmpty else { return client }
        var c = client
        c.model = m
        return c
    }

    func isAvailable() async -> Bool {
        await activeClient.isReachable()
    }

    func cleanup(_ raw: String, context: CleanupContext) async -> (text: String, wasCleaned: Bool) {
        // Nothing to clean.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (raw, false)
        }

        let system = promptBuilder.systemPrompt(for: context)
        let user = promptBuilder.userPrompt(rawTranscript: raw)

        guard let output = await activeClient.generate(system: system, user: user) else {
            return (raw, false)   // unavailable / timeout / error
        }

        let cleaned = Self.sanitize(output)
        guard !cleaned.isEmpty else { return (raw, false) }
        return (cleaned, true)
    }

    // MARK: - Defensive output sanitizing

    /// Strips model preamble, wrapping quotes, and code fences that small models
    /// sometimes add despite the "output ONLY the cleaned text" instruction.
    static func sanitize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading conversational preamble on its own line, e.g.
        // "Sure, here's the cleaned text:" / "Here is the cleaned-up version:".
        result = stripLeadingPreamble(result)

        // Strip an enclosing ``` code fence (with optional language tag).
        result = stripCodeFence(result)

        // Strip a single layer of matching wrapping quotes.
        result = stripWrappingQuotes(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingPreamble(_ text: String) -> String {
        // Split off the first line; if it looks like a preamble ("... :") and
        // there is more content after it, drop it.
        guard let newlineIndex = text.firstIndex(of: "\n") else { return text }
        let firstLine = String(text[text.startIndex..<newlineIndex])
            .trimmingCharacters(in: .whitespaces)
        let rest = String(text[text.index(after: newlineIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return text }

        let lower = firstLine.lowercased()
        let preambleCue = firstLine.hasSuffix(":")
            && (lower.hasPrefix("sure")
                || lower.hasPrefix("here")
                || lower.hasPrefix("here's")
                || lower.hasPrefix("here is")
                || lower.contains("cleaned")
                || lower.contains("cleaned-up")
                || lower.contains("cleaned up"))
        return preambleCue ? rest : text
    }

    private static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        lines.removeFirst()                              // opening ``` (maybe with lang)
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()                           // closing ```
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")
        ]
        for (open, close) in pairs where text.first == open && text.last == close {
            let inner = String(text.dropFirst().dropLast())
            // Only unwrap if the delimiter doesn't recur inside (avoid mangling
            // legitimately quoted content).
            if !inner.contains(open) && !inner.contains(close) {
                return inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
