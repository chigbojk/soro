import XCTest
@testable import Soro

@MainActor
final class StoreTests: XCTestCase {

    func testTranscriptStoreAddRecentSearchDelete() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = TranscriptStore(paths: paths)

        let a = Transcript(text: "the quick brown fox", recordingDuration: 2, date: 100)
        let b = Transcript(text: "lazy dog jumps", recordingDuration: 3, date: 200)
        let c = Transcript(text: "another fox appears", recordingDuration: 1, date: 300)
        store.add(a); store.add(b); store.add(c)

        // recent() is date desc.
        let recent = store.recent(limit: 10)
        XCTAssertEqual(recent.map { $0.id }, [c.id, b.id, a.id])
        XCTAssertEqual(store.lastTranscript?.id, c.id)

        // paging
        let page = store.recent(limit: 1, offset: 1)
        XCTAssertEqual(page.map { $0.id }, [b.id])

        // search
        let foxes = store.search("fox", limit: 10)
        XCTAssertEqual(Set(foxes.map { $0.id }), [a.id, c.id])
        XCTAssertTrue(store.search("FOX", limit: 10).count == 2, "search is case-insensitive")

        // delete
        store.delete(id: c.id)
        XCTAssertEqual(store.recent(limit: 10).map { $0.id }, [b.id, a.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.transcriptFile(id: c.id).path))
    }

    func testTranscriptStoreLazyIndexFromDisk() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        // Write files directly, then a fresh store must index them lazily.
        for i in 0..<5 {
            let t = Transcript(text: "record \(i)", recordingDuration: 1, date: Double(i))
            try JSONFile.write(t, to: paths.transcriptFile(id: t.id))
        }
        let store = TranscriptStore(paths: paths)
        XCTAssertEqual(store.count, 5)
        XCTAssertEqual(store.recent(limit: 10).count, 5)
    }

    func testGlossaryApplyReplacements() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = GlossaryStore(paths: paths)
        store.add(GlossaryEntry(term: "my email", isReplacement: true, replacement: "jordan@chigbo.net"))
        store.add(GlossaryEntry(term: "disabled", isEnabled: false, isReplacement: true, replacement: "X"))
        store.add(GlossaryEntry(term: "Supabase", isReplacement: false))

        let out = store.applyReplacements(to: "please send it to my email today")
        XCTAssertEqual(out, "please send it to jordan@chigbo.net today")

        // disabled replacement not applied
        XCTAssertEqual(store.applyReplacements(to: "a disabled b"), "a disabled b")

        // enabledTerms excludes replacements + disabled
        XCTAssertEqual(store.enabledTerms(), ["Supabase"])
    }

    func testGlossaryPersistsToDisk() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        do {
            let store = GlossaryStore(paths: paths)
            store.add(GlossaryEntry(term: "Soro"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.glossaryFile.path))
        let reloaded = GlossaryStore(paths: paths)
        XCTAssertEqual(reloaded.entries.map { $0.term }, ["Soro"])
    }

    func testPreferencesStoreRoundTrip() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PreferencesStore(paths: paths)
        store.prefs.privacyMode = true
        store.prefs.ollamaModel = "llama3.2:1b"
        store.save()

        let raw = try rawJSON(at: paths.preferencesFile)
        XCTAssertEqual(raw["privacyMode"] as? Bool, true)

        let reloaded = PreferencesStore(paths: paths)
        XCTAssertTrue(reloaded.prefs.privacyMode)
        XCTAssertEqual(reloaded.prefs.ollamaModel, "llama3.2:1b")
    }

    func testStatsDerivations() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StatsStore(paths: paths)
        store.recordDictation(words: 60, duration: 60)  // 60 wpm
        XCTAssertEqual(store.stats.lifetimeDictations, 1)
        XCTAssertEqual(store.dictatedWords, 60)
        XCTAssertEqual(store.avgWPM, 60)
        XCTAssertGreaterThan(store.timeSavedSeconds, 0)
    }

    func testAutoDictionaryFrequency() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = AutoDictionaryStore(paths: paths)
        store.observe(transcript: "I use Supabase and Supabase daily")
        store.observe(transcript: "Supabase again")
        // "Supabase" seen 3x → suggested; count threshold is 2.
        XCTAssertTrue(store.suggestions().contains("Supabase"))
        store.dismiss("Supabase")
        XCTAssertFalse(store.suggestions().contains("Supabase"))
    }

    func testPersonalizationStyleFor() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)
        store.prefs.casualMessagingStyle = "casual"
        store.prefs.emailStyle = "formal"
        XCTAssertEqual(store.styleFor(.casual).messaging, "casual")
        XCTAssertEqual(store.styleFor(.email).messaging, "formal")
    }
}
