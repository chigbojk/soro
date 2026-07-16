import Foundation
import AppKit
import AudioToolbox

/// Plays subtle start/stop/done tones for dictation events (brief M9 §3).
///
/// Uses system sounds from NSSound (named) or AudioServicesPlaySystemSound as
/// fallback. All calls are fire-and-forget; no error surfacing.
/// Instantiate once and call the appropriate method from DictationCoordinator
/// state transitions.
struct DictationSounds {
    /// Play the recording-start tone. Subtle, short.
    static func playStart() {
        // "Tink" is a crisp, brief system tone (NSSound named).
        play(named: "Tink", fallbackID: 1104)
    }

    /// Play the recording-stop tone.
    static func playStop() {
        play(named: "Pop", fallbackID: 1105)
    }

    /// Play the success / text-inserted tone.
    static func playSuccess() {
        play(named: "Morse", fallbackID: 1057)
    }

    // MARK: - Internal

    private static func play(named name: String, fallbackID: SystemSoundID) {
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            AudioServicesPlaySystemSound(fallbackID)
        }
    }
}
