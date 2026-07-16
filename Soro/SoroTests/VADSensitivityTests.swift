import XCTest
@testable import Soro

/// Unit tests for the VAD sensitivity → DecodingOptions mapping in
/// WhisperKitTranscriptionService.decodeOptionsFor(sensitivity:).
///
/// The mapping contract:
///   0.0 (aggressive)  → noSpeechThreshold ~0.8, VAD ON
///   0.5 (midpoint)    → noSpeechThreshold ~0.55, VAD ON
///   1.0 (keep all)    → noSpeechThreshold ~0.3, VAD OFF
///
/// Higher sensitivity = lower noSpeechThreshold = fewer segments dropped.
final class VADSensitivityTests: XCTestCase {

    // MARK: - Extreme: aggressive (0.0)

    func testAggressiveSensitivityHasHighNoSpeechThreshold() {
        let (threshold, _) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 0.0)
        // At 0.0 the threshold should be near 0.8
        XCTAssertEqual(threshold, 0.8, accuracy: 0.001,
                       "sensitivity=0.0 should yield noSpeechThreshold≈0.8")
    }

    func testAggressiveSensitivityEnablesVAD() {
        let (_, useVAD) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 0.0)
        XCTAssertTrue(useVAD, "sensitivity=0.0 should enable VAD chunking")
    }

    // MARK: - Extreme: keep everything (1.0)

    func testMaxSensitivityHasLowNoSpeechThreshold() {
        let (threshold, _) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 1.0)
        // At 1.0 the threshold should be near 0.3
        XCTAssertEqual(threshold, 0.3, accuracy: 0.001,
                       "sensitivity=1.0 should yield noSpeechThreshold≈0.3")
    }

    func testMaxSensitivityDisablesVAD() {
        let (_, useVAD) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 1.0)
        XCTAssertFalse(useVAD, "sensitivity=1.0 should disable VAD chunking so short clips survive")
    }

    // MARK: - Midpoint (0.5)

    func testMidpointSensitivityHasMidNoSpeechThreshold() {
        let (threshold, _) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 0.5)
        // noSpeechThreshold = 0.8 - 0.5 * 0.5 = 0.55
        XCTAssertEqual(threshold, 0.55, accuracy: 0.001,
                       "sensitivity=0.5 should yield noSpeechThreshold≈0.55")
    }

    func testMidpointSensitivityEnablesVAD() {
        let (_, useVAD) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 0.5)
        XCTAssertTrue(useVAD, "sensitivity=0.5 should still enable VAD chunking")
    }

    // MARK: - VAD boundary (0.8)

    func testVADDisabledAtAndAboveThreshold() {
        // VAD should be disabled at sensitivity=0.8 (boundary)
        let (_, useVAD80) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 0.8)
        XCTAssertFalse(useVAD80, "sensitivity=0.8 should disable VAD (boundary)")

        let (_, useVAD85) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 0.85)
        XCTAssertFalse(useVAD85, "sensitivity=0.85 should disable VAD (above boundary)")
    }

    func testVADEnabledBelowBoundary() {
        let (_, useVAD) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 0.79)
        XCTAssertTrue(useVAD, "sensitivity=0.79 should still enable VAD (just below boundary)")
    }

    // MARK: - Clamping

    func testSensitivityBelowZeroIsClamped() {
        let (threshold, useVAD) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: -0.5)
        XCTAssertEqual(threshold, 0.8, accuracy: 0.001, "values below 0.0 are clamped to 0.0")
        XCTAssertTrue(useVAD, "clamped value should enable VAD")
    }

    func testSensitivityAboveOneIsClamped() {
        let (threshold, useVAD) = WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: 1.5)
        XCTAssertEqual(threshold, 0.3, accuracy: 0.001, "values above 1.0 are clamped to 1.0")
        XCTAssertFalse(useVAD, "clamped value should disable VAD")
    }

    // MARK: - Monotonicity

    func testNoSpeechThresholdDecreasesWithSensitivity() {
        let sensitivities = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }
        let thresholds = sensitivities.map {
            WhisperKitTranscriptionService.decodeOptionsFor(sensitivity: $0).noSpeechThreshold
        }
        for i in 0..<thresholds.count - 1 {
            XCTAssertGreaterThanOrEqual(
                thresholds[i], thresholds[i + 1],
                "noSpeechThreshold must decrease (or stay equal) as sensitivity increases"
            )
        }
    }

    // MARK: - Preferences persistence

    @MainActor
    func testVadSensitivityPersistedInPreferences() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }

        let store = PreferencesStore(paths: paths)
        store.prefs.vadSensitivity = 0.75
        store.save()

        let store2 = PreferencesStore(paths: paths)
        XCTAssertEqual(store2.prefs.vadSensitivity, 0.75,
                       "vadSensitivity must round-trip through preferences.json")
    }

    @MainActor
    func testVadSensitivityDefaultsToHalfWhenAbsentInJSON() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }

        // Write a minimal prefs JSON without vadSensitivity key (simulates old installs).
        let minimal: [String: Any] = [
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
            "selectedHotkey": [
                "keyCode": 58, "keyName": "Left Option",
                "isModifierOnlyTrigger": true, "isRightModifier": false,
                "additionalModifiers": [] as [Int], "nonModifierKeys": [] as [Int],
                "modifiers": 0, "isMouseButton": false, "mouseButton": 0
            ],
            "hotkeyData": [
                "keyCode": 58, "keyName": "Left Option",
                "isModifierOnlyTrigger": true, "isRightModifier": false,
                "additionalModifiers": [] as [Int], "nonModifierKeys": [] as [Int],
                "modifiers": 0, "isMouseButton": false, "mouseButton": 0
            ],
            "handsFreeModeHotkeyDataArray": [] as [[String: Any]],
            "pasteTranscriptHotkeyDataArray": [] as [[String: Any]],
            "commandModeHotkeyDataArray": [] as [[String: Any]]
        ]
        let data = try JSONSerialization.data(withJSONObject: minimal)
        try data.write(to: paths.preferencesFile, options: .atomic)

        let store = PreferencesStore(paths: paths)
        // nil means absent in JSON; the UI falls back to 0.5 via the `?? 0.5` guard.
        XCTAssertNil(store.prefs.vadSensitivity,
                     "vadSensitivity should be nil when missing from JSON (backwards compat)")
    }
}
