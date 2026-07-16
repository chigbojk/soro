import Foundation
import AppKit

/// A snapshot of the frontmost app at record start (brief §5, App C).
struct ContextSnapshot: Sendable {
    let appName: String
    let bundleId: String
    let context: DictationContext
    /// True for a *literal* code editor where output must stay verbatim (VS Code,
    /// Cursor's editor surface). Kept for the existing `CleanupContext.isCodeEditor`
    /// wiring — see `CleanupService`/`DictationCoordinator`.
    let isCodeEditor: Bool
    /// True when the surface is technical prose: a terminal (Terminal, iTerm2,
    /// Warp, Ghostty, Alacritty) or an AI-prompt / coding-assistant surface
    /// (Claude, ChatGPT, Cursor, VS Code). In these contexts the prose SHOULD be
    /// cleaned (filler, punctuation, lists) but technical tokens — filenames,
    /// camelCase, snake_case, ACRONYMS, CLI commands, paths, dev product names —
    /// must be preserved verbatim. Distinct from `isCodeEditor` (pure literal
    /// code). The `DictationContext` enum stays `.work` for all of these; this
    /// finer flag is what the prompt uses.
    let isAIPromptOrCode: Bool
}

/// Detects the frontmost app and maps its bundle id → context bucket (brief §5).
/// Snapshot is taken at *record start*, never at insertion time (App C).
enum ContextDetector {
    private static let casualBundles: Set<String> = [
        "com.apple.MobileSMS", "com.apple.iChat",
        "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.burbn.instagram"
    ]
    private static let emailBundles: Set<String> = [
        "com.apple.mail"
    ]

    /// Terminal emulators — technical-prose surfaces (the user dictates into a
    /// shell or a terminal AI agent like Claude Code CLI).
    private static let terminalBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",           // iTerm2
        "dev.warp.Warp-Stable",            // Warp
        "com.mitchellh.ghostty",           // Ghostty
        "io.alacritty",                    // Alacritty
        "org.alacritty",                   // Alacritty (alt id)
        "net.kovidgoyal.kitty",            // kitty
        "co.zeit.hyper"                    // Hyper
    ]

    /// AI-assistant / prompt surfaces — technical prose (you're writing an
    /// instruction to a coding agent, not code itself).
    private static let aiPromptBundles: Set<String> = [
        "com.anthropic.claudefordesktop",  // Claude desktop
        "com.openai.chat",                 // ChatGPT desktop
        "com.todesktop.230313mzl4w4u92"    // Cursor (chat + editor; treated as tech prose)
    ]

    /// Pure code editors — output stays literal. (Cursor is also here because its
    /// editor pane is a literal surface; the AI/terminal-prose treatment still
    /// applies via `isAIPromptOrCode`, and the prompt reconciles the two.)
    private static let codeEditorBundles: Set<String> = [
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.microsoft.VSCode"
    ]

    /// Non-technical `.work` apps (Notion, Linear, etc.) — prose surfaces that are
    /// NOT technical, so the preserve-tokens clause does not apply.
    private static let workBundles: Set<String> = [
        "notion.id", "com.linear"
    ]

    static func snapshot() -> ContextSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? "Unknown"
        return ContextSnapshot(
            appName: name,
            bundleId: bundleId,
            context: bucket(for: bundleId),
            isCodeEditor: isCodeEditor(bundleId: bundleId),
            isAIPromptOrCode: isAIPromptOrCode(bundleId: bundleId))
    }

    static func bucket(for bundleId: String) -> DictationContext {
        if casualBundles.contains(bundleId) { return .casual }
        if emailBundles.contains(bundleId) { return .email }
        // Terminals, AI-prompt surfaces, code editors and the general work apps
        // all map to `.work` (enum stays stable per docs/CONTRACTS.md).
        if terminalBundles.contains(bundleId)
            || aiPromptBundles.contains(bundleId)
            || codeEditorBundles.contains(bundleId)
            || workBundles.contains(bundleId) { return .work }
        return .other
    }

    /// A literal code editor (VS Code / Cursor). Output must stay verbatim.
    static func isCodeEditor(bundleId: String) -> Bool {
        codeEditorBundles.contains(bundleId)
    }

    /// A technical-prose surface: terminal, AI-prompt/coding-assistant, or code
    /// editor. In these the prose is cleaned but technical tokens are preserved
    /// verbatim. The `DictationContext` stays `.work`; this is the finer flag the
    /// prompt consumes.
    static func isAIPromptOrCode(bundleId: String) -> Bool {
        terminalBundles.contains(bundleId)
            || aiPromptBundles.contains(bundleId)
            || codeEditorBundles.contains(bundleId)
    }
}
