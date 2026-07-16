import Foundation

/// Builds the Ollama cleanup system prompt from context (brief Appendix B).
///
/// The template structure follows Appendix B verbatim; bracketed variables are
/// filled from the `CleanupContext`. The raw transcript is passed separately as
/// the user message (see `userPrompt`) so the system prompt stays stable and
/// cacheable, but `fullPrompt` is also exposed for callers/tests that want the
/// exact Appendix-B single-block form.
struct PromptBuilder {

    /// The system prompt — everything up to (but not including) the raw
    /// transcript block. Filled from context per Appendix B.
    func systemPrompt(for context: CleanupContext) -> String {
        var lines: [String] = []

        // Technical-prose surfaces (terminals like Terminal/iTerm2/Warp/Ghostty
        // and AI-prompt / coding-assistant surfaces like Claude Code CLI, ChatGPT,
        // Cursor, VS Code) are `.work` context but need the preserve-technical-
        // tokens clause. Derived from the frozen `CleanupContext` (bundleId +
        // isCodeEditor) so we don't change the struct signature (docs/CONTRACTS.md).
        let isTechnicalProse = context.isCodeEditor
            || ContextDetector.isAIPromptOrCode(bundleId: context.bundleId)

        // For technical contexts, augment the personal dictionary with a seed of
        // known dev product names (DevJargon) so the model keeps their casing.
        let effectiveTerms = isTechnicalProse
            ? DevJargon.augment(context.glossaryTerms)
            : context.glossaryTerms

        lines.append("You clean up raw voice-dictation transcripts. Output ONLY the cleaned text — no quotes, no preamble, no commentary, no explanation.")
        lines.append("")
        lines.append("Rules:")
        lines.append("- BE FAITHFUL. Keep the speaker's own words, meaning, and intent. You are CLEANING, not rewriting or answering. Never invent content, never reply to the message, never paraphrase into different words. If unsure, keep it closer to the original.")
        lines.append("- Remove filler words and disfluencies: um, uh, er, like, you know, sort of, false starts, repeated words.")
        lines.append("- Apply self-corrections: if the speaker retracts or changes something (\"no wait\", \"scratch that\", \"I mean\", \"actually change that to\", \"delete that\"), output ONLY the final intended text. Never include the retracted words or the correction phrase.")
        lines.append("- Fix capitalization, punctuation, and obvious transcription errors. Do not change the meaning or add content the speaker did not say.")
        lines.append("- Infer structure from intent, without needing explicit commands:")
        lines.append("  - If the speaker enumerates items, format as a list. Use a NUMBERED list when they count them off — \"first/second/third\", \"one/two/three\", \"step one/two\", \"number one\", or repeated \"and then\". Use a BULLETED list (\"- \") when they rattle off several distinct items or actions without counting — e.g. \"I need milk, eggs, and bread\", or \"we should call the client, update the deck, and book the room\". When in doubt between a paragraph and a list of 2+ distinct items, prefer the list.")
        lines.append("  - Strip the counting words themselves from the output (\"one\", \"two\", \"first\", \"and then\") — the list numbers/bullets replace them.")
        lines.append("  - Start a new paragraph when the topic clearly shifts.")
        lines.append("  - Leave a single short thought as one plain sentence. Do NOT over-format.")
        lines.append("- Honor explicit spoken formatting commands and then remove the command word: \"new line\", \"new paragraph\", \"bullet point\", \"next point\", \"dash\", literal \"period/comma/question mark/colon\".")
        if isTechnicalProse {
            // The user is dictating into a terminal or an AI coding assistant
            // (e.g. Claude Code CLI). Clean the PROSE but never mangle code tokens.
            lines.append("- TECHNICAL CONTEXT: this is a terminal or AI coding-assistant prompt. Clean the prose normally (remove filler, fix punctuation, make lists) BUT preserve technical tokens EXACTLY as spoken — do NOT reword, split, or re-case them: filenames (e.g. Foo.tsx, package.json), camelCase and snake_case identifiers, ALL-CAPS acronyms (API, URL, HTTP, JSON, SQL), CLI commands and flags, file paths, and known dev product names (Supabase, Vercel, Cloudflare, Postgres, Next.js, Tailwind, Xcode, Docker, npm, and the like).")
            lines.append("- Do NOT translate spoken symbol names inside commands/paths incorrectly: keep literal shell syntax as the speaker means it (e.g. a flag stays a flag). Only convert a spoken symbol to text when it is clearly meant literally in the command.")
        }
        lines.append("- Preserve these exact terms/spellings if they appear (personal dictionary): \(glossaryField(effectiveTerms)).")
        lines.append("")
        lines.append("Destination app: \(appNameField(context.appName)) (context: \(context.context.rawValue)).")
        lines.append("Writing tone: \(messagingStyleField(context.messagingStyle)). Style: \(scribeStyleField(context.scribeStyle)). Extra instruction: \(personalTweakField(context.personalTweak)).")
        lines.append("For casual contexts, keep it relaxed and brief. For email/work, be clear and appropriately polished.")
        if context.isCodeEditor {
            // A literal code editor pane: stay verbatim.
            lines.append("This is a literal code editor: stay literal — do not reflow into prose or add Markdown the editor won't render. Emit what was dictated, only fixing obvious transcription slips in identifiers.")
        } else if isTechnicalProse {
            // Terminal / AI-prompt prose: DO clean the prose, just keep the tokens.
            lines.append("This is technical prose (terminal or AI coding-assistant prompt): DO clean the prose into clear sentences and lists as usual, but keep every technical token verbatim per the TECHNICAL CONTEXT rule above.")
        }
        lines.append("")
        lines.append(styleSamplesField(context.styleSamples))
        lines.append("")
        lines.append(Self.examplesBlock)

        return lines.joined(separator: "\n")
    }

    /// The user message: the raw transcript wrapped in the Appendix-B fenced
    /// block. Kept out of the system prompt so the model sees it as the payload.
    func userPrompt(rawTranscript: String) -> String {
        "Raw transcript:\n\"\"\"\n\(rawTranscript)\n\"\"\""
    }

    /// The full single-block Appendix-B prompt (system + transcript). Useful for
    /// callers that submit one blob and for snapshot tests.
    func fullPrompt(for context: CleanupContext, rawTranscript: String) -> String {
        systemPrompt(for: context) + "\n\n" + userPrompt(rawTranscript: rawTranscript)
    }

    /// Few-shot examples — small local models (llama3.2:3b) need worked
    /// input→output pairs to reliably apply the list-formatting rules.
    static let examplesBlock = """
    Examples (input → output):

    Input: um so first check the audio then second check the transcription then third check the paste
    Output:
    1. Check the audio.
    2. Check the transcription.
    3. Check the paste.

    Input: one do this two do that three do the other thing
    Output:
    1. Do this.
    2. Do that.
    3. Do the other thing.

    Input: I need to grab milk eggs and some bread from the shop
    Output:
    - Milk
    - Eggs
    - Bread

    Input: we should call the client update the deck and book the room
    Output:
    - Call the client
    - Update the deck
    - Book the room

    Input: hey can you send me the file when you get a chance
    Output: Hey, can you send me the file when you get a chance?
    """

    // MARK: - Field filling

    private func glossaryField(_ terms: [String]) -> String {
        terms.isEmpty ? "(none)" : terms.joined(separator: ", ")
    }

    private func appNameField(_ name: String) -> String {
        name.isEmpty ? "the current app" : name
    }

    private func messagingStyleField(_ style: String) -> String {
        style.isEmpty ? "casual" : style
    }

    private func scribeStyleField(_ style: String) -> String {
        style.isEmpty ? "natural" : style
    }

    private func personalTweakField(_ tweak: String) -> String {
        let trimmed = tweak.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(none)" : trimmed
    }

    /// The `[STYLE_SAMPLES: …]` line. When samples exist, render them as tone
    /// anchors; otherwise emit the empty-state placeholder from Appendix B.
    private func styleSamplesField(_ samples: [String]) -> String {
        let clean = samples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
        guard !clean.isEmpty else {
            return "Recent accepted outputs from this context (as tone anchors): none yet."
        }
        var out = "Recent accepted outputs from this context (as tone anchors):"
        for sample in clean {
            out += "\n- \(sample)"
        }
        return out
    }
}
