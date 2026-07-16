import Foundation

/// The high-level gestures the hotkey engine emits (brief §2). The manager owns
/// no business logic — it translates raw key events into these.
enum HotkeyGesture: Sendable {
    case pushToTalkBegan, pushToTalkEnded
    case lockToggledOn, lockToggledOff
    case cancel                       // Esc while recording
    case pasteLastTranscript
    /// Triple-tap Left Option → show a transient toast with the current microphone
    /// name. Purely informational; does not affect recording (§ toasts-tripletap).
    case showMicrophone
}
