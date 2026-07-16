import Foundation
import Combine

/// JSON-backed store for `Transcripts/<UUID>.json` — one file per record.
///
/// Assumes ~10k files. Maintains a lazily-built in-memory index of
/// `(id, date, snippet)` (first ~200 chars), sorted by `date` desc. The full
/// record is loaded from disk only when actually requested. Search runs over
/// the index snippets.
@MainActor
final class TranscriptStore: ObservableObject {
    /// A lightweight index row — never holds the full transcript text.
    struct IndexEntry {
        let id: UUID
        let date: Double
        let snippet: String            // first ~200 chars, lowercased for search
        let displaySnippet: String     // first ~200 chars, original case
    }

    private let paths: AppPaths
    private var index: [IndexEntry]?   // nil until first access (lazy)

    init(paths: AppPaths = .live) {
        self.paths = paths
    }

    // MARK: Index

    private func ensureIndex() -> [IndexEntry] {
        if let index { return index }
        let built = buildIndex()
        index = built
        return built
    }

    private func buildIndex() -> [IndexEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: paths.transcripts,
            includingPropertiesForKeys: nil) else { return [] }

        var rows: [IndexEntry] = []
        rows.reserveCapacity(files.count)
        for url in files where url.pathExtension == "json" {
            guard let t = JSONFile.read(Transcript.self, from: url) else { continue }
            let snippet = String(t.text.prefix(200))
            rows.append(IndexEntry(
                id: t.id,
                date: t.date,
                snippet: snippet.lowercased(),
                displaySnippet: snippet))
        }
        rows.sort { $0.date > $1.date }
        return rows
    }

    private func load(id: UUID) -> Transcript? {
        JSONFile.read(Transcript.self, from: paths.transcriptFile(id: id))
    }

    // MARK: Mutations

    func add(_ t: Transcript) {
        // Build the index (from existing files) BEFORE writing, so a first-access
        // build doesn't also pick up this new record and double-count it.
        var idx = ensureIndex()
        try? JSONFile.write(t, to: paths.transcriptFile(id: t.id))
        let snippet = String(t.text.prefix(200))
        let row = IndexEntry(id: t.id, date: t.date,
                             snippet: snippet.lowercased(),
                             displaySnippet: snippet)
        idx.removeAll { $0.id == t.id }   // replace on re-add
        idx.append(row)
        idx.sort { $0.date > $1.date }
        index = idx
        objectWillChange.send()
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: paths.transcriptFile(id: id))
        if var idx = index {
            idx.removeAll { $0.id == id }
            index = idx
        }
        objectWillChange.send()
    }

    // MARK: Queries

    /// Most recent transcripts (date desc), paged.
    func recent(limit: Int, offset: Int = 0) -> [Transcript] {
        let idx = ensureIndex()
        guard offset < idx.count else { return [] }
        let slice = idx[offset..<min(offset + limit, idx.count)]
        return slice.compactMap { load(id: $0.id) }
    }

    /// Case-insensitive substring search over the index snippets, date desc.
    func search(_ q: String, limit: Int) -> [Transcript] {
        let needle = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return recent(limit: limit) }
        let idx = ensureIndex()
        var results: [Transcript] = []
        for row in idx where row.snippet.contains(needle) {
            if let t = load(id: row.id) {
                results.append(t)
                if results.count >= limit { break }
            }
        }
        return results
    }

    /// The single most recent transcript.
    var lastTranscript: Transcript? {
        guard let first = ensureIndex().first else { return nil }
        return load(id: first.id)
    }

    /// Total record count (for stats / paging).
    var count: Int { ensureIndex().count }
}
