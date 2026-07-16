import XCTest
@testable import Soro

/// Unit tests for M8-dictionary logic.
/// These test pure store logic that underpins DictionaryView —
/// no live UI rendering (avoids needing a display or accessibility).
@MainActor
final class DictionaryViewTests: XCTestCase {

    // MARK: - GlossaryStore: terms vs. shortcuts split

    func testGlossaryTermsAndShortcutsAreSeparate() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = GlossaryStore(paths: paths)

        let term = GlossaryEntry(term: "Supabase", isReplacement: false)
        let shortcut = GlossaryEntry(term: "my email", isReplacement: true, replacement: "jordan@chigbo.net")
        store.add(term)
        store.add(shortcut)

        let terms = store.entries.filter { !$0.isReplacement }
        let shortcuts = store.entries.filter { $0.isReplacement }

        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].term, "Supabase")

        XCTAssertEqual(shortcuts.count, 1)
        XCTAssertEqual(shortcuts[0].term, "my email")
        XCTAssertEqual(shortcuts[0].replacement, "jordan@chigbo.net")
    }

    // MARK: - GlossaryStore: enable/disable toggle

    func testGlossaryToggleEnabled() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = GlossaryStore(paths: paths)

        var entry = GlossaryEntry(term: "Soro", isEnabled: true, isReplacement: false)
        store.add(entry)

        // Disable
        entry.isEnabled = false
        store.update(entry)
        XCTAssertFalse(store.entries.first { $0.id == entry.id }?.isEnabled ?? true)

        // Re-enable
        entry.isEnabled = true
        store.update(entry)
        XCTAssertTrue(store.entries.first { $0.id == entry.id }?.isEnabled ?? false)
    }

    // MARK: - GlossaryStore: search filtering (simulating DictionaryView logic)

    func testSearchFilterMatchesTerm() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = GlossaryStore(paths: paths)

        store.add(GlossaryEntry(term: "Supabase", isReplacement: false))
        store.add(GlossaryEntry(term: "Firebase", isReplacement: false))
        store.add(GlossaryEntry(term: "PostgreSQL", isReplacement: false))

        let q = "base"
        let results = store.entries.filter { $0.term.lowercased().contains(q) }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.map { $0.term }.contains("Supabase"))
        XCTAssertTrue(results.map { $0.term }.contains("Firebase"))
    }

    func testSearchFilterMatchesReplacementText() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = GlossaryStore(paths: paths)

        store.add(GlossaryEntry(term: "my email", isReplacement: true, replacement: "jordan@chigbo.net"))
        store.add(GlossaryEntry(term: "home address", isReplacement: true, replacement: "123 Main St"))

        let q = "chigbo"
        let results = store.entries.filter { entry in
            entry.term.lowercased().contains(q) ||
            (entry.replacement?.lowercased().contains(q) ?? false)
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].term, "my email")
    }

    // MARK: - GlossaryStore: delete

    func testGlossaryDeleteRemovesEntry() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = GlossaryStore(paths: paths)

        let entry = GlossaryEntry(term: "DeleteMe", isReplacement: false)
        store.add(entry)
        XCTAssertEqual(store.entries.count, 1)

        store.delete(id: entry.id)
        XCTAssertEqual(store.entries.count, 0)
    }

    // MARK: - GlossaryStore: auto-learned tag round-trip

    func testAutoLearnedTagPreservedOnDisk() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }

        do {
            let store = GlossaryStore(paths: paths)
            let entry = GlossaryEntry(term: "Supabase", tag: "Auto-Learned", isReplacement: false)
            store.add(entry)
        }

        let reloaded = GlossaryStore(paths: paths)
        XCTAssertEqual(reloaded.entries.first?.tag, "Auto-Learned")
    }

    // MARK: - AutoDictionaryStore: suggestions exclude already-added glossary terms

    func testAutoLearnedSuggestionsExcludeGlossaryEntries() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }

        let glossary = GlossaryStore(paths: paths)
        let autoDict = AutoDictionaryStore(paths: paths)

        // Observe "Supabase" enough to trigger a suggestion
        autoDict.observe(transcript: "Supabase is great")
        autoDict.observe(transcript: "Supabase is fast")
        autoDict.observe(transcript: "Using Supabase")

        // Before adding to glossary, it should be suggested
        let before = autoDict.suggestions()
        XCTAssertTrue(before.contains("Supabase"))

        // Add it to glossary
        glossary.add(GlossaryEntry(term: "Supabase", isReplacement: false))

        // Now simulate DictionaryView's filtering of suggestions
        let alreadyAdded = Set(glossary.entries.map { $0.term.lowercased() })
        let filtered = autoDict.suggestions().filter { !alreadyAdded.contains($0.lowercased()) }
        XCTAssertFalse(filtered.contains("Supabase"))
    }

    // MARK: - AutoDictionaryStore: dismiss prevents re-suggestion

    func testAutoDictionaryDismissPreventsSuggestion() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)

        store.observe(transcript: "Soro app is great")
        store.observe(transcript: "Soro does dictation")

        XCTAssertTrue(store.suggestions().contains("Soro"))
        store.dismiss("Soro")
        XCTAssertFalse(store.suggestions().contains("Soro"))
    }

    // MARK: - AddTermSheet: logic for new term (via GlossaryEntry init)

    func testNewTermCreatesMyTermsTag() {
        let entry = GlossaryEntry(
            term: "Soro",
            tag: "My Terms",
            isEnabled: true,
            isReplacement: false,
            replacement: nil
        )
        XCTAssertEqual(entry.tag, "My Terms")
        XCTAssertFalse(entry.isReplacement)
        XCTAssertNil(entry.replacement)
    }

    func testNewShortcutHasReplacement() {
        let entry = GlossaryEntry(
            term: "my email",
            tag: "My Terms",
            isEnabled: true,
            isReplacement: true,
            replacement: "jordan@chigbo.net"
        )
        XCTAssertTrue(entry.isReplacement)
        XCTAssertEqual(entry.replacement, "jordan@chigbo.net")
    }

    // MARK: - EditTermSheet: updating a term

    func testEditUpdatesTermAndPreservesID() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = GlossaryStore(paths: paths)

        let original = GlossaryEntry(term: "Supa", isReplacement: false)
        store.add(original)

        var updated = original
        updated.term = "Supabase"
        store.update(updated)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].term, "Supabase")
        XCTAssertEqual(store.entries[0].id, original.id)
    }
}
