import Foundation

/// The dictation-context bucket derived from the frontmost app (brief §5).
enum DictationContext: String, Codable, Sendable {
    case casual, email, work, other
}

/// App settings, mirroring `Preferences/preferences.json` (brief §6).
/// Every key listed in the brief is present with a sensible default.
struct Preferences: Codable, Equatable {
    // Audio / language
    var selectedMicrophoneUID: String
    var appLanguage: String
    var selectedLanguages: [String]
    var isAutoDetectLanguage: Bool

    // Privacy / behaviour toggles
    var privacyMode: Bool
    var contextAwareness: Bool
    var enableAutoDictionary: Bool
    var smartTextInsertion: Bool
    var enableNotchView: Bool
    var hideBar: Bool
    var hideBarWhenIdle: Bool
    var audioRecordingSounds: Bool
    var launchAtLogin: Bool
    var showMenuBarIcon: Bool
    var cursorAutomaticEnter: Bool
    var messagesLowercase: Bool

    // Offline mode — in this clone we are always offline.
    var offlineMode: Bool
    var alwaysUseOfflineMode: Bool

    // Model / cleanup selection
    var whisperModel: String
    var ollamaModel: String
    var cleanupEnabled: Bool

    // Hotkeys
    var selectedHotkey: HotkeyData
    var hotkeyData: HotkeyData
    var handsFreeModeHotkeyDataArray: [HotkeyData]
    var pasteTranscriptHotkeyDataArray: [HotkeyData]
    var commandModeHotkeyDataArray: [HotkeyData]

    // Recording bar persisted frame (nil until moved).
    var barFrameX: Double?
    var barFrameY: Double?
    // Full "x,y,w,h" frame string persisted by RecordingBarPanel (nil until moved).
    // Optional so older preferences.json without this key still decode (§6 compat).
    var barFrameString: String?

    // Onboarding — optional so old preferences.json without this key still decodes (M9).
    var hasCompletedOnboarding: Bool?

    // VAD sensitivity (0.0 = aggressive filtering, 1.0 = keep everything).
    // Optional so older preferences.json without this key still decodes (§6 compat).
    var vadSensitivity: Double?

    static let `default` = Preferences(
        selectedMicrophoneUID: "",
        appLanguage: "en",
        selectedLanguages: ["en"],
        isAutoDetectLanguage: false,
        privacyMode: false,
        contextAwareness: true,
        enableAutoDictionary: true,
        smartTextInsertion: true,
        enableNotchView: true,
        hideBar: false,
        hideBarWhenIdle: true,
        audioRecordingSounds: true,
        launchAtLogin: false,
        showMenuBarIcon: true,
        cursorAutomaticEnter: false,
        messagesLowercase: true,
        offlineMode: true,
        alwaysUseOfflineMode: true,
        whisperModel: "openai_whisper-small.en",
        ollamaModel: "llama3.2:3b",
        cleanupEnabled: true,
        selectedHotkey: .leftOption,
        hotkeyData: .leftOption,
        handsFreeModeHotkeyDataArray: [.leftOption],
        pasteTranscriptHotkeyDataArray: [],
        commandModeHotkeyDataArray: [],
        barFrameX: nil,
        barFrameY: nil,
        barFrameString: nil,
        hasCompletedOnboarding: false,
        vadSensitivity: 0.5
    )
}
