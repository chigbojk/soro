import XCTest
@testable import Soro

/// Tests for SettingsView-related pure logic:
/// - PreferencesStore round-trips every field that SettingsView binds to
/// - HotkeyData round-trip
/// - Language picker serialisation
/// - Whisper model names match Preferences defaults
@MainActor
final class SettingsViewTests: XCTestCase {

    var paths: AppPaths!

    override func setUp() {
        super.setUp()
        paths = makeTempPaths()
    }

    override func tearDown() {
        removeTemp(paths)
        super.tearDown()
    }

    // MARK: - PreferencesStore persistence (fields SettingsView binds to)

    func testMicrophoneUIDPersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.selectedMicrophoneUID = "UNIT-TEST-MIC-UID"
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.selectedMicrophoneUID, "UNIT-TEST-MIC-UID")
    }

    func testWhisperModelPersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.whisperModel = "openai_whisper-small.en"
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.whisperModel, "openai_whisper-small.en")
    }

    func testOllamaModelPersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.ollamaModel = "llama3.1:8b"
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.ollamaModel, "llama3.1:8b")
    }

    func testCleanupEnabledTogglePersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.cleanupEnabled = false
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertFalse(store2.prefs.cleanupEnabled)
    }

    func testLanguageSelectionPersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.selectedLanguages = ["fr"]
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.selectedLanguages.first, "fr")
    }

    func testAutoDetectLanguagePersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.isAutoDetectLanguage = true
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertTrue(store2.prefs.isAutoDetectLanguage)
    }

    func testPrivacyModePersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.privacyMode = true
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertTrue(store2.prefs.privacyMode)
    }

    func testAudioRecordingSoundsPersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.audioRecordingSounds = false
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertFalse(store2.prefs.audioRecordingSounds)
    }

    func testShowMenuBarIconPersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.showMenuBarIcon = false
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertFalse(store2.prefs.showMenuBarIconValue)
    }

    func testHideBarWhenIdlePersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.hideBarWhenIdle = false
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertFalse(store2.prefs.hideBarWhenIdle)
    }

    func testCursorAutomaticEnterPersisted() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.cursorAutomaticEnter = true
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertTrue(store2.prefs.cursorAutomaticEnter)
    }

    // MARK: - Hotkey binding round-trip

    func testHotkeyDataRoundTrip() throws {
        let original = HotkeyData(
            keyCode: 58,
            keyName: "Left Option",
            isModifierOnlyTrigger: true,
            isRightModifier: false,
            additionalModifiers: [],
            nonModifierKeys: [],
            modifiers: 0,
            isMouseButton: false,
            mouseButton: 0
        )

        let store = PreferencesStore(paths: paths)
        store.prefs.hotkeyData = original
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.hotkeyData, original)
    }

    func testHotkeyDataSecondaryArrayRoundTrip() throws {
        let paste = HotkeyData(
            keyCode: 9,
            keyName: "V",
            isModifierOnlyTrigger: false,
            isRightModifier: false,
            additionalModifiers: [55],
            nonModifierKeys: [9],
            modifiers: 0,
            isMouseButton: false,
            mouseButton: 0
        )

        let store = PreferencesStore(paths: paths)
        store.prefs.pasteTranscriptHotkeyDataArray = [paste]
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.pasteTranscriptHotkeyDataArray.first, paste)
    }

    // MARK: - JSON key names (brief §6 compliance)

    func testPreferencesJSONKeysMatchBrief() throws {
        let store = PreferencesStore(paths: paths)
        store.save()

        let raw = try rawJSON(at: paths.preferencesFile)

        // Keys that SettingsView binds to must match the brief §6 JSON spec
        XCTAssertNotNil(raw["selectedMicrophoneUID"],    "selectedMicrophoneUID key missing")
        XCTAssertNotNil(raw["whisperModel"],             "whisperModel key missing")
        XCTAssertNotNil(raw["ollamaModel"],              "ollamaModel key missing")
        XCTAssertNotNil(raw["cleanupEnabled"],           "cleanupEnabled key missing")
        XCTAssertNotNil(raw["selectedLanguages"],        "selectedLanguages key missing")
        XCTAssertNotNil(raw["isAutoDetectLanguage"],     "isAutoDetectLanguage key missing")
        XCTAssertNotNil(raw["privacyMode"],              "privacyMode key missing")
        XCTAssertNotNil(raw["audioRecordingSounds"],     "audioRecordingSounds key missing")
        XCTAssertNotNil(raw["showMenuBarIcon"],          "showMenuBarIcon key missing")
        XCTAssertNotNil(raw["hideBarWhenIdle"],          "hideBarWhenIdle key missing")
        XCTAssertNotNil(raw["cursorAutomaticEnter"],     "cursorAutomaticEnter key missing")
        XCTAssertNotNil(raw["launchAtLogin"],            "launchAtLogin key missing")
        XCTAssertNotNil(raw["hotkeyData"],               "hotkeyData key missing")
    }

    // MARK: - Default model name

    func testDefaultWhisperModelMatchesModelManager() {
        // The persisted default must agree with ModelManager.defaultModel (small.en) —
        // they were previously inconsistent (pref said base.en, warm-up used small.en).
        XCTAssertEqual(Preferences.default.whisperModel, "openai_whisper-small.en")
        XCTAssertEqual(Preferences.default.whisperModel, ModelManager.defaultModel)
    }

    func testDefaultOllamaModelIsLlama() {
        XCTAssertTrue(Preferences.default.ollamaModel.hasPrefix("llama"))
    }

    // MARK: - Language array single-select semantics

    func testFirstLanguageUsedAsSingleSelect() {
        var prefs = Preferences.default
        prefs.selectedLanguages = ["de", "en"]
        XCTAssertEqual(prefs.selectedLanguages.first, "de",
                       "SettingsView reads .first for single-select; array order must be preserved")
    }
}

// MARK: - Accessor shim (avoids editing Preferences.swift)

private extension Preferences {
    var showMenuBarIconValue: Bool { showMenuBarIcon }
}
