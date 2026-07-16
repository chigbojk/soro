import Foundation

/// Persists a recording to `Recordings/recording_<ISO8601>.wav` (brief §3a, §6).
/// Writes 16 kHz mono 16-bit PCM WAV — playable by the History UI's AVAudioPlayer.
struct RecordingWriter {
    let paths: AppPaths

    init(paths: AppPaths = .live) {
        self.paths = paths
    }

    /// The destination URL for a new recording, ISO8601-timestamped (§6).
    /// Colons in the ISO8601 stamp are replaced so the name is filesystem-safe
    /// while remaining sortable and human-readable.
    func recordingURL(date: Date = Date()) -> URL {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = fmt.string(from: date).replacingOccurrences(of: ":", with: "-")
        return paths.recordings.appendingPathComponent("recording_\(stamp).wav")
    }

    /// Encodes `samples` (16 kHz mono Float) to a WAV file and writes it atomically.
    /// Returns the URL on success, `nil` if the write failed (caller degrades to
    /// a nil `fileURL`, never hangs — brief cross-cutting rule).
    @discardableResult
    func write(samples: [Float], sampleRate: Int = 16_000, date: Date = Date()) -> URL? {
        let url = recordingURL(date: date)
        let data = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Deletes a recording (privacy mode, or cancel).
    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
