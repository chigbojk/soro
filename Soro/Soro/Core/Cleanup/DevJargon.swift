import Foundation

/// A small seed of well-known developer product / tooling names that should be
/// preserved verbatim (correct casing, no "translation") when dictating into a
/// technical-prose surface — a terminal or an AI coding assistant like Claude
/// Code CLI (brief §3d/§5A).
///
/// This is intentionally NOT part of the `CleanupContext` struct (whose signature
/// is frozen by docs/CONTRACTS.md). Instead `PromptBuilder` augments the
/// context's `glossaryTerms` with this static list ONLY for technical contexts,
/// so casual/email dictation is unaffected.
///
/// Keep this short and high-signal: these are names the small local model most
/// often mis-cases or splits (e.g. "next JS" → "Next.js", "post grass" →
/// "Postgres"). The user's own personal dictionary always takes precedence and
/// is listed first.
enum DevJargon {
    /// Canonical spellings of common dev product / framework / tool names.
    static let terms: [String] = [
        // Databases / backends
        "Supabase", "Postgres", "PostgreSQL", "Redis", "SQLite", "MongoDB",
        "Firebase", "Prisma",
        // Hosting / infra / cloud
        "Vercel", "Cloudflare", "Netlify", "AWS", "Docker", "Kubernetes",
        "Terraform", "nginx",
        // Frameworks / libraries
        "Next.js", "React", "Vue", "Svelte", "Node.js", "Deno", "Bun",
        "Tailwind", "TypeScript", "JavaScript", "SwiftUI", "Django", "FastAPI",
        // Tooling / editors / CLIs
        "Xcode", "VS Code", "Vim", "Neovim", "tmux", "npm", "pnpm", "Yarn",
        "Vite", "Webpack", "ESLint", "Prettier", "GitHub", "GitLab",
        // AI / agent surfaces
        "Claude", "Claude Code", "Anthropic", "Ollama", "ChatGPT", "OpenAI",
        "Cursor", "Copilot",
        // Languages / runtimes
        "Rust", "Golang", "Kotlin", "GraphQL", "JSON", "YAML", "HTML", "CSS"
    ]

    /// Merge the user's own glossary terms (highest priority, kept first and
    /// de-duplicated case-insensitively) with the dev-jargon seed. Returns a
    /// stable-ordered list with the personal terms ahead of the seed.
    static func augment(_ userTerms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in userTerms + terms {
            let key = term.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(term)
        }
        return result
    }
}
