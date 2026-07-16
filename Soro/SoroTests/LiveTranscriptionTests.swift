import XCTest
@testable import Soro

/// End-to-end transcription against the REAL downloaded Whisper model and a REAL
/// recording from the live app-support directory. Skips (does not fail) when the
/// model or a recording is absent, so CI/fresh checkouts stay green.
final class LiveTranscriptionTests: XCTestCase {

    private var livePaths: AppPaths { .live }

    private func newestRecording() -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: livePaths.recordings, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return files
            .filter { $0.pathExtension == "wav" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    /// Minimal 16kHz mono 16-bit PCM WAV reader (matches WAVEncoder's output).
    private func loadWAVSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return [] }
        // Find the "data" chunk rather than assuming a fixed 44-byte header.
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = data.subdata(in: offset+4..<offset+8).withUnsafeBytes { $0.load(as: UInt32.self) }
            if id == "data" {
                let start = offset + 8
                let end = min(start + Int(size), data.count)
                let pcm = data.subdata(in: start..<end)
                return pcm.withUnsafeBytes { raw in
                    let int16 = raw.bindMemory(to: Int16.self)
                    return int16.map { Float($0) / Float(Int16.max) }
                }
            }
            offset += 8 + Int(size) + (Int(size) % 2)
        }
        return []
    }

    func testTranscribeRealRecordingWithRealModel() async throws {
        // Skip on CI — this can download a ~500MB Whisper model and run Core ML,
        // which is slow/nondeterministic on a hosted runner.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "Skipping model-download test on CI")
        // Find the newest recording that actually holds >1s of audio — short
        // synthetic/test clips can leave sub-second WAVs as the literal newest file.
        let fm = FileManager.default
        let wavs = ((try? fm.contentsOfDirectory(
            at: livePaths.recordings, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        var picked: (URL, [Float])?
        for w in wavs {
            let s = (try? loadWAVSamples(w)) ?? []
            if s.count > 16_000 { picked = (w, s); break }
        }
        guard let (wav, samples) = picked else {
            throw XCTSkip("No recording longer than 1s present on this machine")
        }
        let audio = CapturedAudio(samples: samples,
                                  duration: TimeInterval(samples.count) / 16_000,
                                  fileURL: wav)

        // Ensures the default model (small.en) is downloaded + loaded, then
        // transcribes with the production decode options (VAD + fallback guards).
        let service = WhisperKitTranscriptionService(paths: livePaths)
        try await service.prepareModel(ModelManager.defaultModel) { _ in }
        let text = try await service.transcribe(audio, language: "en", initialPrompt: nil)

        XCTAssertFalse(text.isEmpty, "transcription must produce text")
        XCTAssertNotEqual(text, "ERROR_TRANSCRIBING")
        print("LIVE TRANSCRIPTION [\(ModelManager.defaultModel)]: \(text)")
    }
}
