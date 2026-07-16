import Foundation
import XCTest
@testable import Soro

final class CleanupTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext(
        appName: String = "Messages",
        bundleId: String = "com.apple.MobileSMS",
        context: DictationContext = .casual,
        messagingStyle: String = "casual",
        scribeStyle: String = "natural",
        personalTweak: String = "",
        glossaryTerms: [String] = [],
        styleSamples: [String] = [],
        isCodeEditor: Bool = false
    ) -> CleanupContext {
        CleanupContext(
            appName: appName, bundleId: bundleId, context: context,
            messagingStyle: messagingStyle, scribeStyle: scribeStyle,
            personalTweak: personalTweak, glossaryTerms: glossaryTerms,
            styleSamples: styleSamples, isCodeEditor: isCodeEditor)
    }

    // MARK: - Prompt construction snapshot

    func testSystemPromptStructureVerbatim() {
        let ctx = makeContext(
            appName: "Mail", bundleId: "com.apple.mail", context: .email,
            messagingStyle: "formal", scribeStyle: "polished",
            personalTweak: "sign off with Best",
            glossaryTerms: ["Supabase", "Y Combinator"],
            styleSamples: ["Thanks so much for the update.", "Talk soon."])
        let prompt = PromptBuilder().systemPrompt(for: ctx)

        // Appendix-B opening line, verbatim.
        XCTAssertTrue(prompt.hasPrefix("You clean up raw voice-dictation transcripts. Output ONLY the cleaned text — no quotes, no preamble, no commentary, no explanation."))
        // Rules block present.
        XCTAssertTrue(prompt.contains("Remove filler words and disfluencies"))
        XCTAssertTrue(prompt.contains("Apply self-corrections"))
        XCTAssertTrue(prompt.contains("Infer structure from intent"))
        XCTAssertTrue(prompt.contains("Honor explicit spoken formatting commands"))
        // Filled variables.
        XCTAssertTrue(prompt.contains("Preserve these exact terms/spellings if they appear (personal dictionary): Supabase, Y Combinator."))
        XCTAssertTrue(prompt.contains("Destination app: Mail (context: email)."))
        XCTAssertTrue(prompt.contains("Writing tone: formal. Style: polished. Extra instruction: sign off with Best."))
        // Style samples rendered.
        XCTAssertTrue(prompt.contains("Thanks so much for the update."))
        XCTAssertTrue(prompt.contains("Talk soon."))
    }

    func testSystemPromptEmptyFieldsUsePlaceholders() {
        let ctx = makeContext(
            appName: "", messagingStyle: "", scribeStyle: "",
            personalTweak: "   ", glossaryTerms: [], styleSamples: [])
        let prompt = PromptBuilder().systemPrompt(for: ctx)

        XCTAssertTrue(prompt.contains("(personal dictionary): (none)."))
        XCTAssertTrue(prompt.contains("Destination app: the current app"))
        XCTAssertTrue(prompt.contains("Writing tone: casual. Style: natural. Extra instruction: (none)."))
        XCTAssertTrue(prompt.contains("none yet."))
    }

    func testUserPromptWrapsTranscriptInFence() {
        let user = PromptBuilder().userPrompt(rawTranscript: "hello world")
        XCTAssertEqual(user, "Raw transcript:\n\"\"\"\nhello world\n\"\"\"")
    }

    func testStyleSamplesCappedAtThreeInPrompt() {
        let ctx = makeContext(styleSamples: ["one", "two", "three", "four", "five"])
        let prompt = PromptBuilder().systemPrompt(for: ctx)
        XCTAssertTrue(prompt.contains("- one"))
        XCTAssertTrue(prompt.contains("- three"))
        XCTAssertFalse(prompt.contains("- four"))
        XCTAssertFalse(prompt.contains("- five"))
    }

    // MARK: - Fallback on refused connection

    func testCleanupFallsBackWhenOllamaUnreachable() async {
        let service = OllamaCleanupService(client: deadPortClient())
        let (text, cleaned) = await service.cleanup("um so first do x", context: makeContext())
        XCTAssertEqual(text, "um so first do x")
        XCTAssertFalse(cleaned)
    }

    func testIsAvailableFalseWhenUnreachable() async {
        let service = OllamaCleanupService(client: deadPortClient())
        let available = await service.isAvailable()
        XCTAssertFalse(available)
    }

    func testEmptyInputShortCircuits() async {
        // Even with a real client, empty input must not hit the network.
        let service = OllamaCleanupService(client: deadPortClient())
        let (text, cleaned) = await service.cleanup("   ", context: makeContext())
        XCTAssertEqual(text, "   ")
        XCTAssertFalse(cleaned)
    }

    /// A client aimed at an almost-certainly-unused loopback port — connections
    /// are refused fast, simulating "Ollama not running".
    private func deadPortClient() -> OllamaClient {
        OllamaClient(
            availabilityTimeout: 0.5, generateTimeout: 0.5,
            baseURL: URL(string: "http://127.0.0.1:59237")!)
    }

    // MARK: - Preamble / quote stripping

    func testSanitizeStripsLeadingPreamble() {
        let out = OllamaCleanupService.sanitize("Sure, here's the cleaned text:\nHello there.")
        XCTAssertEqual(out, "Hello there.")
    }

    func testSanitizeStripsHereIsPreamble() {
        let out = OllamaCleanupService.sanitize("Here is the cleaned-up version:\nBuy oat milk.")
        XCTAssertEqual(out, "Buy oat milk.")
    }

    func testSanitizeStripsWrappingDoubleQuotes() {
        XCTAssertEqual(OllamaCleanupService.sanitize("\"Hello there.\""), "Hello there.")
    }

    func testSanitizeStripsSmartQuotes() {
        XCTAssertEqual(OllamaCleanupService.sanitize("“Hello there.”"), "Hello there.")
    }

    func testSanitizeStripsCodeFence() {
        let out = OllamaCleanupService.sanitize("```\nlet x = 1\n```")
        XCTAssertEqual(out, "let x = 1")
    }

    func testSanitizeStripsCodeFenceWithLang() {
        let out = OllamaCleanupService.sanitize("```swift\nlet x = 1\n```")
        XCTAssertEqual(out, "let x = 1")
    }

    func testSanitizeLeavesCleanTextUntouched() {
        XCTAssertEqual(OllamaCleanupService.sanitize("Just clean text."), "Just clean text.")
    }

    func testSanitizeDoesNotUnwrapInternalQuotes() {
        // Legitimately quoted content inside must be preserved.
        let input = "She said \"hi\" and left."
        XCTAssertEqual(OllamaCleanupService.sanitize(input), "She said \"hi\" and left.")
    }

    func testSanitizeDoesNotStripNonPreambleFirstLine() {
        let input = "First do x.\nSecond do y."
        XCTAssertEqual(OllamaCleanupService.sanitize(input), "First do x.\nSecond do y.")
    }

    // MARK: - Context mapping table (§5)

    func testContextMappingTable() {
        let cases: [(String, DictationContext)] = [
            ("com.apple.MobileSMS", .casual),
            ("com.apple.iChat", .casual),
            ("net.whatsapp.WhatsApp", .casual),
            ("com.tinyspeck.slackmacgap", .casual),
            ("com.hnc.Discord", .casual),
            ("com.apple.mail", .email),
            ("com.todesktop.230313mzl4w4u92", .work),  // Cursor
            ("com.microsoft.VSCode", .work),
            ("com.apple.Terminal", .work),
            ("com.googlecode.iterm2", .work),
            ("notion.id", .work),
            ("com.some.unknown.app", .other),
            ("", .other)
        ]
        for (bundle, expected) in cases {
            XCTAssertEqual(ContextDetector.bucket(for: bundle), expected,
                           "bundle \(bundle) should map to \(expected)")
        }
    }

    func testCodeEditorFlagInSnapshotMapping() {
        // Code editors are a subset of the work bucket.
        XCTAssertEqual(ContextDetector.bucket(for: "com.microsoft.VSCode"), .work)
        XCTAssertEqual(ContextDetector.bucket(for: "com.apple.Terminal"), .work)
    }

    // MARK: - Terminal / AI-prompt classification (dev-cli-context)

    /// Terminals and AI-prompt surfaces stay in the `.work` bucket (enum stable)
    /// but are flagged `isAIPromptOrCode`. Casual/email/other are not.
    func testTechnicalProseClassificationTable() {
        // (bundle, mapped context, isCodeEditor, isAIPromptOrCode)
        let cases: [(String, DictationContext, Bool, Bool)] = [
            // Terminals → work, not literal-code, but technical prose.
            ("com.apple.Terminal",        .work,  false, true),
            ("com.googlecode.iterm2",     .work,  false, true),
            ("dev.warp.Warp-Stable",      .work,  false, true),
            ("com.mitchellh.ghostty",     .work,  false, true),
            ("io.alacritty",              .work,  false, true),
            // AI-prompt surfaces → work, technical prose.
            ("com.anthropic.claudefordesktop", .work, false, true),
            ("com.openai.chat",           .work,  false, true),
            // Cursor: literal editor AND technical prose.
            ("com.todesktop.230313mzl4w4u92", .work, true, true),
            ("com.microsoft.VSCode",      .work,  true,  true),
            // Non-technical work apps: work, but NOT technical prose.
            ("notion.id",                 .work,  false, false),
            ("com.linear",                .work,  false, false),
            // Casual / email / other: not technical prose.
            ("com.apple.MobileSMS",       .casual, false, false),
            ("com.apple.mail",            .email,  false, false),
            ("com.some.unknown.app",      .other,  false, false),
            ("",                          .other,  false, false)
        ]
        for (bundle, ctx, isCode, isTech) in cases {
            XCTAssertEqual(ContextDetector.bucket(for: bundle), ctx,
                           "bundle \(bundle) → context")
            XCTAssertEqual(ContextDetector.isCodeEditor(bundleId: bundle), isCode,
                           "bundle \(bundle) → isCodeEditor")
            XCTAssertEqual(ContextDetector.isAIPromptOrCode(bundleId: bundle), isTech,
                           "bundle \(bundle) → isAIPromptOrCode")
        }
    }

    // MARK: - Preserve-technical-tokens clause (dev-cli-context)

    private static let techClauseMarker = "TECHNICAL CONTEXT:"

    /// Terminal / AI-prompt prose gets the preserve-tokens clause, cleans prose,
    /// and augments the glossary with the DevJargon seed.
    func testTechnicalContextIncludesPreserveTokensClause() {
        let ctx = makeContext(
            appName: "Terminal", bundleId: "com.apple.Terminal",
            context: .work, isCodeEditor: false)
        let prompt = PromptBuilder().systemPrompt(for: ctx)

        XCTAssertTrue(prompt.contains(Self.techClauseMarker),
                      "terminal context must carry the preserve-technical-tokens clause")
        XCTAssertTrue(prompt.contains("technical prose (terminal or AI coding-assistant prompt): DO clean the prose"),
                      "terminal prose is cleaned, not left literal")
        // DevJargon seed augmented in.
        XCTAssertTrue(prompt.contains("Supabase"))
        XCTAssertTrue(prompt.contains("Next.js"))
        XCTAssertTrue(prompt.contains("Vercel"))
    }

    func testAIPromptContextIncludesPreserveTokensClause() {
        let ctx = makeContext(
            appName: "Claude", bundleId: "com.anthropic.claudefordesktop",
            context: .work, isCodeEditor: false)
        let prompt = PromptBuilder().systemPrompt(for: ctx)
        XCTAssertTrue(prompt.contains(Self.techClauseMarker))
    }

    /// A literal code editor keeps tokens too, but stays literal (no prose reflow).
    func testCodeEditorStaysLiteral() {
        let ctx = makeContext(
            appName: "VS Code", bundleId: "com.microsoft.VSCode",
            context: .work, isCodeEditor: true)
        let prompt = PromptBuilder().systemPrompt(for: ctx)
        XCTAssertTrue(prompt.contains(Self.techClauseMarker),
                      "code editor still preserves technical tokens")
        XCTAssertTrue(prompt.contains("literal code editor: stay literal"),
                      "code editor stays literal")
        XCTAssertFalse(prompt.contains("technical prose (terminal or AI coding-assistant prompt): DO clean the prose"),
                       "code editor must NOT be told to reflow prose")
    }

    /// Non-technical contexts (casual/email and even non-technical `.work` apps
    /// like Notion) must NOT carry the clause or the DevJargon seed.
    func testNonTechnicalContextsOmitClause() {
        let casual = makeContext(
            appName: "Messages", bundleId: "com.apple.MobileSMS",
            context: .casual, isCodeEditor: false)
        let casualPrompt = PromptBuilder().systemPrompt(for: casual)
        XCTAssertFalse(casualPrompt.contains(Self.techClauseMarker))
        XCTAssertFalse(casualPrompt.contains("Supabase"),
                       "casual context must not inject dev jargon")

        let notion = makeContext(
            appName: "Notion", bundleId: "notion.id",
            context: .work, isCodeEditor: false)
        let notionPrompt = PromptBuilder().systemPrompt(for: notion)
        XCTAssertFalse(notionPrompt.contains(Self.techClauseMarker),
                       "non-technical work app must not carry the tech clause")
        XCTAssertFalse(notionPrompt.contains("Supabase"))
    }

    // MARK: - DevJargon augmentation

    func testDevJargonAugmentKeepsUserTermsFirstAndDedupes() {
        let merged = DevJargon.augment(["MyProject", "supabase"])
        // User terms come first.
        XCTAssertEqual(merged.first, "MyProject")
        // Case-insensitive dedupe: user's "supabase" wins over seed "Supabase".
        XCTAssertTrue(merged.contains("supabase"))
        XCTAssertFalse(merged.contains("Supabase"))
        // Seed still present.
        XCTAssertTrue(merged.contains("Vercel"))
    }

    func testDevJargonAugmentEmptyUserTerms() {
        let merged = DevJargon.augment([])
        XCTAssertEqual(merged, DevJargon.terms)
    }

    // MARK: - StyleSampleStore ring buffer

    func testStyleSampleRingBuffer() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StyleSampleStore(paths: paths, capacity: 5)

        for i in 1...7 {
            store.append("sample \(i)", for: .casual)
        }
        let recent = store.recent(3, for: .casual)
        // Oldest two ("1","2") evicted by capacity 5; recent(3) → newest three.
        XCTAssertEqual(recent, ["sample 5", "sample 6", "sample 7"])

        // Isolated per context.
        XCTAssertTrue(store.recent(3, for: .work).isEmpty)
    }

    func testStyleSampleIgnoresBlank() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StyleSampleStore(paths: paths)
        store.append("   ", for: .work)
        XCTAssertTrue(store.recent(3, for: .work).isEmpty)
    }

    func testStyleSamplePersistsAcrossInstances() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let a = StyleSampleStore(paths: paths)
        a.append("hello", for: .email)

        let b = StyleSampleStore(paths: paths)
        XCTAssertEqual(b.recent(3, for: .email), ["hello"])
    }

    // MARK: - Live smoke test (skips gracefully if Ollama/model absent)

    func testLiveCleanupSmoke() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Skipping live Ollama test on CI")
        // Generous timeout so a cold model load doesn't trip the 4s production
        // fallback — this test verifies cleanup *quality*, not the timeout path
        // (which `testCleanupFallsBackWhenOllamaUnreachable` covers).
        let client = OllamaClient(generateTimeout: 60)
        guard await client.isReachable() else {
            throw XCTSkip("Ollama not reachable on 127.0.0.1:11434")
        }
        guard await client.installedModels().contains(where: { $0.hasPrefix("llama3.2:3b") }) else {
            throw XCTSkip("llama3.2:3b not installed")
        }
        let service = OllamaCleanupService(client: client)
        let (text, cleaned) = await service.cleanup(
            "um so first do x second do y", context: makeContext())
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(cleaned)
        XCTAssertNotEqual(text, "um so first do x second do y")
    }
}
