import Foundation
import Combine

/// JSON-backed store for `Preferences/glossary.json`.
@MainActor
final class GlossaryStore: ObservableObject {
    @Published var entries: [GlossaryEntry] {
        didSet { save() }
    }

    private let paths: AppPaths

    init(paths: AppPaths = .live) {
        self.paths = paths
        self.entries = JSONFile.read([GlossaryEntry].self, from: paths.glossaryFile) ?? []
    }

    // MARK: CRUD

    func add(_ entry: GlossaryEntry) {
        entries.append(entry)
    }

    func update(_ entry: GlossaryEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        }
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func save() {
        try? JSONFile.write(entries, to: paths.glossaryFile)
    }

    // MARK: Pipeline helpers

    /// Enabled non-replacement terms — passed to whisper as biasing prompt (§3c).
    func enabledTerms() -> [String] {
        entries
            .filter { $0.isEnabled && !$0.isReplacement }
            .map { $0.term }
    }

    /// Applies enabled replacement shortcuts as literal case-insensitive find/replace (§3c).
    func applyReplacements(to text: String) -> String {
        var result = text
        for entry in entries where entry.isEnabled && entry.isReplacement {
            guard let replacement = entry.replacement, !entry.term.isEmpty else { continue }
            result = result.replacingOccurrences(
                of: entry.term,
                with: replacement,
                options: [.caseInsensitive])
        }
        return result
    }
}
