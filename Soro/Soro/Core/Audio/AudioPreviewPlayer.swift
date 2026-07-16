import Foundation
import AVFoundation

/// Plays back recorded transcript audio in the HomeView history panel (brief M9 §4).
///
/// Holds a single `AVAudioPlayer`; starting a new playback stops the previous.
/// Designed to be held for the app lifetime — one instance shared across HomeView.
@MainActor
final class AudioPreviewPlayer: NSObject, ObservableObject {
    @Published private(set) var currentlyPlayingID: UUID? = nil

    private var player: AVAudioPlayer?

    /// Play the audio at `url`. Stops any currently playing audio first.
    /// Silently no-ops if the file doesn't exist or can't be decoded.
    func play(id: UUID, url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            currentlyPlayingID = id
        } catch {
            // File exists but isn't playable (codec mismatch, etc.) — silently skip.
        }
    }

    /// Stop any current playback.
    func stop() {
        player?.stop()
        player = nil
        currentlyPlayingID = nil
    }

    /// Toggle: if this id is already playing, stop; otherwise start.
    func toggle(id: UUID, url: URL) {
        if currentlyPlayingID == id {
            stop()
        } else {
            play(id: id, url: url)
        }
    }
}

extension AudioPreviewPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.currentlyPlayingID = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.player = nil
            self.currentlyPlayingID = nil
        }
    }
}
