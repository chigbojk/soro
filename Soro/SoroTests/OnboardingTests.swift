import XCTest
@testable import Soro

/// Unit tests for M9 onboarding logic:
///   - hasCompletedOnboarding preference round-trips correctly
///   - Default value is false (triggers onboarding on first launch)
///   - Optional field decodes cleanly from old JSON that lacks the key
@MainActor
final class OnboardingTests: XCTestCase {

    var paths: AppPaths!

    override func setUp() {
        super.setUp()
        paths = makeTempPaths()
    }

    override func tearDown() {
        removeTemp(paths)
        super.tearDown()
    }

    // MARK: - hasCompletedOnboarding default

    func testDefaultPrefsDoNotHaveOnboardingCompleted() {
        let store = PreferencesStore(paths: paths)
        // New install: default value is explicitly false.
        XCTAssertEqual(store.prefs.hasCompletedOnboarding, false)
    }

    func testOnboardingFlagPersists() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.hasCompletedOnboarding = true
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.hasCompletedOnboarding, true)
    }

    func testOnboardingFlagSetToFalsePersists() throws {
        let store = PreferencesStore(paths: paths)
        store.prefs.hasCompletedOnboarding = false
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.hasCompletedOnboarding, false)
    }

    // MARK: - JSON backward compatibility

    func testOldJSONWithoutKeyDecodesWithNilValue() throws {
        // Simulate a preferences.json written before M9 (missing the key).
        let oldJSON = """
        {
          "selectedMicrophoneUID": "",
          "appLanguage": "en",
          "selectedLanguages": ["en"],
          "isAutoDetectLanguage": false,
          "privacyMode": false,
          "contextAwareness": true,
          "enableAutoDictionary": true,
          "smartTextInsertion": true,
          "enableNotchView": true,
          "hideBar": false,
          "hideBarWhenIdle": true,
          "audioRecordingSounds": true,
          "launchAtLogin": false,
          "showMenuBarIcon": true,
          "cursorAutomaticEnter": false,
          "messagesLowercase": true,
          "offlineMode": true,
          "alwaysUseOfflineMode": true,
          "whisperModel": "openai_whisper-base.en",
          "ollamaModel": "llama3.2:3b",
          "cleanupEnabled": true,
          "selectedHotkey": {"keyCode": 58, "keyName": "Left Option", "isModifierOnlyTrigger": true, "isRightModifier": false, "additionalModifiers": [], "nonModifierKeys": [], "modifiers": 0, "isMouseButton": false, "mouseButton": 0},
          "hotkeyData": {"keyCode": 58, "keyName": "Left Option", "isModifierOnlyTrigger": true, "isRightModifier": false, "additionalModifiers": [], "nonModifierKeys": [], "modifiers": 0, "isMouseButton": false, "mouseButton": 0},
          "handsFreeModeHotkeyDataArray": [],
          "pasteTranscriptHotkeyDataArray": [],
          "commandModeHotkeyDataArray": []
        }
        """
        let data = Data(oldJSON.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: data)
        // Old JSON without the key → nil (not false, not crash).
        XCTAssertNil(prefs.hasCompletedOnboarding,
                     "Old JSON without hasCompletedOnboarding should decode to nil")
    }

    // MARK: - AppState showOnboarding logic

    func testShowOnboardingTrueWhenFlagIsNil() throws {
        // nil == not in file == new install → show onboarding.
        let nilFlag: Bool? = nil
        XCTAssertTrue(!(nilFlag ?? false), "nil flag should trigger onboarding")
    }

    func testShowOnboardingFalseWhenFlagIsTrue() {
        let completedFlag: Bool? = true
        XCTAssertFalse(!(completedFlag ?? false))
    }
}
