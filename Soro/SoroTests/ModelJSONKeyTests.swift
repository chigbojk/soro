import XCTest
@testable import Soro

/// Asserts model JSON keys match brief §6 exactly.
final class ModelJSONKeyTests: XCTestCase {

    private func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTranscriptKeysAndTypes() throws {
        let url = URL(string: "file:///tmp/Recordings/recording_2025-08-29T05:50:30.228Z.wav")!
        let t = Transcript(id: UUID(uuidString: "91286E6C-244A-4028-A947-36FA3E0FDA1B")!,
                           text: "hello world",
                           audioURL: url,
                           recordingDuration: 12.4,
                           date: 778139430.946161)
        let dict = try encodeToDict(t)

        XCTAssertEqual(Set(dict.keys), ["id", "text", "audioURL", "recordingDuration", "date"])
        // date is a Double Cocoa epoch.
        XCTAssertEqual(dict["date"] as? Double, 778139430.946161)
        // audioURL is a file:// URL *string*.
        XCTAssertEqual(dict["audioURL"] as? String, url.absoluteString)
        XCTAssertTrue((dict["audioURL"] as? String)?.hasPrefix("file://") == true)
        XCTAssertEqual(dict["recordingDuration"] as? Double, 12.4)
    }

    func testTranscriptRoundTrip() throws {
        let original = Transcript(text: "round trip", audioURL: nil, recordingDuration: 3.0, date: 100.0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.text, original.text)
        XCTAssertNil(decoded.audioURL)
        XCTAssertEqual(decoded.recordingDuration, 3.0)
        XCTAssertEqual(decoded.date, 100.0)
    }

    func testGlossaryEntryKeys() throws {
        let e = GlossaryEntry(term: "Willow", tag: "My Terms",
                              isEnabled: true, isReplacement: true, replacement: "willow@x.com")
        let dict = try encodeToDict(e)
        XCTAssertTrue(dict.keys.contains("isReplacement"))
        XCTAssertTrue(dict.keys.contains("isEnabled"))
        XCTAssertTrue(dict.keys.contains("term"))
        XCTAssertTrue(dict.keys.contains("tag"))
        XCTAssertTrue(dict.keys.contains("replacement"))
        XCTAssertEqual(dict["isReplacement"] as? Bool, true)
    }

    func testHotkeyDataDefaultIsLeftOption() throws {
        let dict = try encodeToDict(HotkeyData.leftOption)
        XCTAssertEqual(dict["keyCode"] as? Int, 58)
        XCTAssertEqual(dict["keyName"] as? String, "Left Option")
        XCTAssertEqual(dict["isModifierOnlyTrigger"] as? Bool, true)
        for key in ["additionalModifiers", "nonModifierKeys", "modifiers",
                    "isMouseButton", "mouseButton", "isRightModifier"] {
            XCTAssertTrue(dict.keys.contains(key), "missing key \(key)")
        }
    }

    func testPreferencesDefaultHotkeyKeys() throws {
        let dict = try encodeToDict(Preferences.default)
        XCTAssertTrue(dict.keys.contains("hotkeyData"))
        XCTAssertTrue(dict.keys.contains("handsFreeModeHotkeyDataArray"))
        XCTAssertTrue(dict.keys.contains("pasteTranscriptHotkeyDataArray"))
        XCTAssertTrue(dict.keys.contains("commandModeHotkeyDataArray"))
        XCTAssertTrue(dict.keys.contains("privacyMode"))
        let hotkey = try XCTUnwrap(dict["hotkeyData"] as? [String: Any])
        XCTAssertEqual(hotkey["keyCode"] as? Int, 58)
    }

    func testPersonalizationKeys() throws {
        let dict = try encodeToDict(PersonalizationPreferences.default)
        for key in ["workMessagingStyle", "emailStyle", "casualMessagingStyle", "otherStyle",
                    "workScribeWritingStyle", "casualPersonalTweak"] {
            XCTAssertTrue(dict.keys.contains(key), "missing key \(key)")
        }
    }

    func testUsageStatsKeys() throws {
        // The four legacy keys must always be present (feature_usage_stats.json
        // back-compat). Newer additive keys (monthly/appUsage/wordCounts/etc.) may
        // also appear — assert the legacy set is a subset, not an exact match.
        let dict = try encodeToDict(UsageStats.default)
        for key in ["lifetimeDictations", "lifetimeScribeUses", "handsFreeEverUsed", "barEverMoved"] {
            XCTAssertTrue(dict.keys.contains(key), "missing legacy key \(key)")
        }
    }
}
