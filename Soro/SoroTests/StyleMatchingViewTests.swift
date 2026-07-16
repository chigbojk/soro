import XCTest
import SwiftUI
@testable import Soro

/// Tests for M8-style: StyleMatchingView and PersonalizationStore bindings.
@MainActor
final class StyleMatchingViewTests: XCTestCase {

    // MARK: - PersonalizationStore round-trips

    func testDefaultPreferencesMatchBriefSpec() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)

        // Brief §6 specifies these exact defaults.
        XCTAssertEqual(store.prefs.workMessagingStyle, "formal")
        XCTAssertEqual(store.prefs.emailStyle, "formal")
        XCTAssertEqual(store.prefs.casualMessagingStyle, "casual")
        XCTAssertEqual(store.prefs.otherStyle, "formal")

        XCTAssertEqual(store.prefs.workScribeWritingStyle, "natural")
        XCTAssertEqual(store.prefs.emailScribeWritingStyle, "natural")
        XCTAssertEqual(store.prefs.casualScribeWritingStyle, "natural")
        XCTAssertEqual(store.prefs.otherScribeWritingStyle, "natural")

        XCTAssertEqual(store.prefs.workPersonalTweak, "")
        XCTAssertEqual(store.prefs.emailPersonalTweak, "")
        XCTAssertEqual(store.prefs.casualPersonalTweak, "")
        XCTAssertEqual(store.prefs.otherPersonalTweak, "")
    }

    func testPersonalizationPersistsToDisk() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }

        // Write
        do {
            let store = PersonalizationStore(paths: paths)
            store.prefs.workMessagingStyle = "casual"
            store.prefs.emailScribeWritingStyle = "polished"
            store.prefs.casualPersonalTweak = "Keep it super short."
            store.save()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.personalizationFile.path))

        // Reload and verify
        let reloaded = PersonalizationStore(paths: paths)
        XCTAssertEqual(reloaded.prefs.workMessagingStyle, "casual")
        XCTAssertEqual(reloaded.prefs.emailScribeWritingStyle, "polished")
        XCTAssertEqual(reloaded.prefs.casualPersonalTweak, "Keep it super short.")
        // Unchanged values survive reload.
        XCTAssertEqual(reloaded.prefs.otherStyle, "formal")
    }

    func testPersonalizationJSONKeys() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)
        store.save()

        let raw = try rawJSON(at: paths.personalizationFile)

        // All keys from brief §6 must be present.
        let expectedKeys = [
            "workMessagingStyle", "emailStyle",
            "casualMessagingStyle", "otherStyle",
            "workScribeWritingStyle", "emailScribeWritingStyle",
            "casualScribeWritingStyle", "otherScribeWritingStyle",
            "workPersonalTweak", "emailPersonalTweak",
            "casualPersonalTweak", "otherPersonalTweak"
        ]
        for key in expectedKeys {
            XCTAssertNotNil(raw[key], "Missing JSON key: \(key)")
        }
    }

    // MARK: - styleFor context routing

    func testStyleForRoutesByContext() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)

        store.prefs.workMessagingStyle = "formal"
        store.prefs.workScribeWritingStyle = "polished"
        store.prefs.workPersonalTweak = "Be concise."

        store.prefs.emailStyle = "formal"
        store.prefs.emailScribeWritingStyle = "concise"
        store.prefs.emailPersonalTweak = "Sign off professionally."

        store.prefs.casualMessagingStyle = "casual"
        store.prefs.casualScribeWritingStyle = "natural"
        store.prefs.casualPersonalTweak = "Use contractions."

        store.prefs.otherStyle = "formal"
        store.prefs.otherScribeWritingStyle = "natural"
        store.prefs.otherPersonalTweak = ""

        let work = store.styleFor(.work)
        XCTAssertEqual(work.messaging, "formal")
        XCTAssertEqual(work.scribe, "polished")
        XCTAssertEqual(work.tweak, "Be concise.")

        let email = store.styleFor(.email)
        XCTAssertEqual(email.messaging, "formal")
        XCTAssertEqual(email.scribe, "concise")
        XCTAssertEqual(email.tweak, "Sign off professionally.")

        let casual = store.styleFor(.casual)
        XCTAssertEqual(casual.messaging, "casual")
        XCTAssertEqual(casual.scribe, "natural")
        XCTAssertEqual(casual.tweak, "Use contractions.")

        let other = store.styleFor(.other)
        XCTAssertEqual(other.messaging, "formal")
        XCTAssertEqual(other.scribe, "natural")
        XCTAssertEqual(other.tweak, "")
    }

    // MARK: - Mutation via bindings (simulates what StyleMatchingView does)

    func testBindingMutationAndAutosave() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)

        // Simulate what the card's Binding setter does.
        store.prefs.casualMessagingStyle = "formal"
        store.save()

        let reloaded = PersonalizationStore(paths: paths)
        XCTAssertEqual(reloaded.prefs.casualMessagingStyle, "formal")
    }

    func testPersonalTweakSurvivesSpecialCharacters() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)

        let tweak = #"Always use "quotes" & ampersands — em dashes too."#
        store.prefs.workPersonalTweak = tweak
        store.save()

        let reloaded = PersonalizationStore(paths: paths)
        XCTAssertEqual(reloaded.prefs.workPersonalTweak, tweak)
    }

    func testClearPersonalTweak() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)

        store.prefs.emailPersonalTweak = "Some instruction"
        store.save()

        // Simulate user clicking "Clear"
        store.prefs.emailPersonalTweak = ""
        store.save()

        let reloaded = PersonalizationStore(paths: paths)
        XCTAssertEqual(reloaded.prefs.emailPersonalTweak, "")
    }

    // MARK: - Scribe style values

    func testScribeStyleAcceptsAllThreeValues() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = PersonalizationStore(paths: paths)

        for value in ["natural", "polished", "concise"] {
            store.prefs.workScribeWritingStyle = value
            store.save()
            let reloaded = PersonalizationStore(paths: paths)
            XCTAssertEqual(reloaded.prefs.workScribeWritingStyle, value)
        }
    }

    // MARK: - No-crash on missing file (graceful degradation)

    func testMissingFileLoadsDefaults() {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        // Do NOT call save() — file should not exist.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.personalizationFile.path))

        let store = PersonalizationStore(paths: paths)
        // Should silently fall back to defaults, not crash.
        XCTAssertEqual(store.prefs, PersonalizationPreferences.default)
    }
}
