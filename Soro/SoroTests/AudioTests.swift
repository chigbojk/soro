import XCTest
@testable import Soro

/// M2 audio DSP + recording-file tests. All pure/headless — no live mic.
final class AudioTests: XCTestCase {

    // MARK: - Resampler

    func testResampleEmptyAndMatchingRates() {
        XCTAssertTrue(AudioMath.resampleLinear([], from: 44_100, to: 16_000).isEmpty)
        let x: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(AudioMath.resampleLinear(x, from: 16_000, to: 16_000), x)
    }

    func testResampleHalvesCount() {
        // 48 kHz → 16 kHz is a 3:1 decimation; N input → ~N/3 output.
        let input = [Float](repeating: 0, count: 3000)
        let out = AudioMath.resampleLinear(input, from: 48_000, to: 16_000)
        XCTAssertEqual(out.count, 1000)
    }

    func testResampleSineWavePreservesToneAfterDownsample() {
        // Generate a 440 Hz sine at 48 kHz, downsample to 16 kHz, and confirm the
        // dominant frequency is preserved by counting zero crossings.
        let srcRate: Double = 48_000
        let dstRate: Double = 16_000
        let freq: Double = 440
        let seconds: Double = 1.0
        let n = Int(srcRate * seconds)
        var input = [Float](repeating: 0, count: n)
        for i in 0..<n {
            input[i] = Float(sin(2 * .pi * freq * Double(i) / srcRate))
        }

        let out = AudioMath.resampleLinear(input, from: srcRate, to: dstRate)
        XCTAssertEqual(Double(out.count), dstRate * seconds, accuracy: 2)

        // Zero crossings (positive-going) ≈ frequency for a 1 s signal.
        var crossings = 0
        for i in 1..<out.count where out[i - 1] < 0 && out[i] >= 0 { crossings += 1 }
        XCTAssertEqual(Double(crossings), freq, accuracy: 5,
                       "downsampled tone should retain ~440 Hz fundamental")

        // Amplitude of a unit sine is preserved (peak ≈ 1).
        let peak = out.map(abs).max() ?? 0
        XCTAssertEqual(peak, 1.0, accuracy: 0.05)
    }

    func testResampleUpsampleInterpolates() {
        let input: [Float] = [0, 1, 0, 1]
        let out = AudioMath.resampleLinear(input, from: 8_000, to: 16_000)
        XCTAssertGreaterThan(out.count, input.count)
        // Interpolated values stay within the source range.
        XCTAssertTrue(out.allSatisfy { $0 >= -0.001 && $0 <= 1.001 })
    }

    // MARK: - Downmix

    func testDownmixStereoToMonoAverages() {
        // Interleaved L,R: [1,0, 1,0] → mono [0.5, 0.5]
        let interleaved: [Float] = [1, 0, 1, 0]
        let mono = AudioMath.downmixToMono(interleaved, channels: 2)
        XCTAssertEqual(mono, [0.5, 0.5])
    }

    func testDownmixMonoIsIdentity() {
        let x: [Float] = [0.3, -0.7, 0.1]
        XCTAssertEqual(AudioMath.downmixToMono(x, channels: 1), x)
    }

    // MARK: - Level computation

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(AudioMath.rms([Float](repeating: 0, count: 100)), 0)
    }

    func testRMSOfFullScaleSquareIsOne() {
        let s: [Float] = [1, -1, 1, -1]
        XCTAssertEqual(AudioMath.rms(s), 1.0, accuracy: 1e-6)
    }

    func testMicLevelMapping() {
        // Silence → 0, full scale → 1, quiet speech moves the meter above 0.
        XCTAssertEqual(AudioMath.micLevel(rms: 0), 0)
        XCTAssertEqual(AudioMath.micLevel(rms: 1.0), 1, accuracy: 1e-6)

        // -40 dBFS (rms ≈ 0.01) sits well inside a -60…0 window → > 0.
        let quiet = AudioMath.micLevel(rms: 0.01)
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertLessThan(quiet, 1)

        // Monotonic: louder → higher.
        XCTAssertLessThan(AudioMath.micLevel(rms: 0.01),
                          AudioMath.micLevel(rms: 0.1))
    }

    func testMicLevelClampsBelowFloor() {
        // -80 dBFS is below the -60 floor → 0.
        XCTAssertEqual(AudioMath.micLevel(rms: 0.0001), 0)
    }

    // MARK: - WAV encoder round-trip

    func testWAVHeaderIsWellFormed() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(bytes: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(bytes: data[36..<40], encoding: .ascii), "data")

        // Sample rate at byte offset 24 (little-endian UInt32).
        let sr = data[24..<28].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(sr, 16_000)

        // Mono / 16-bit.
        let channels = UInt16(data[22]) | (UInt16(data[23]) << 8)
        XCTAssertEqual(channels, 1)
        let bits = UInt16(data[34]) | (UInt16(data[35]) << 8)
        XCTAssertEqual(bits, 16)
    }

    // MARK: - RecordingWriter

    func testRecordingURLNamingIsTimestampedAndFilesystemSafe() {
        let paths = makeTempPaths(); defer { removeTemp(paths) }
        let writer = RecordingWriter(paths: paths)

        var comps = DateComponents()
        comps.year = 2025; comps.month = 8; comps.day = 29
        comps.hour = 5; comps.minute = 50; comps.second = 30
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        let url = writer.recordingURL(date: date)
        let name = url.lastPathComponent
        XCTAssertTrue(name.hasPrefix("recording_"), name)
        XCTAssertTrue(name.hasSuffix(".wav"), name)
        XCTAssertFalse(name.contains(":"), "colons are unsafe on disk")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Recordings")
    }

    func testRecordingWriterWritesReadableWAV() throws {
        let paths = makeTempPaths(); defer { removeTemp(paths) }
        let writer = RecordingWriter(paths: paths)

        let samples: [Float] = (0..<160).map { Float(sin(Double($0) * 0.1)) }
        let url = try XCTUnwrap(writer.write(samples: samples))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(bytes: data[0..<4], encoding: .ascii), "RIFF")

        writer.delete(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordingWriterUniqueNamesAcrossTimes() {
        let paths = makeTempPaths(); defer { removeTemp(paths) }
        let writer = RecordingWriter(paths: paths)
        let a = writer.recordingURL(date: Date(timeIntervalSince1970: 1000))
        let b = writer.recordingURL(date: Date(timeIntervalSince1970: 2000))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - ModelManager

    func testModelManagerDefaultsAndInstallDetection() {
        let paths = makeTempPaths(); defer { removeTemp(paths) }
        let mgr = ModelManager(paths: paths)

        XCTAssertEqual(ModelManager.defaultModel, "openai_whisper-small.en")
        XCTAssertTrue(ModelManager.availableModels.contains(ModelManager.defaultModel))
        XCTAssertFalse(mgr.isModelInstalled("openai_whisper-base.en"))

        // Simulate a downloaded model folder with a file in it.
        let folder = mgr.modelFolder("openai_whisper-base.en")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("model.mlmodelc").path,
                                       contents: Data([0]))
        XCTAssertTrue(mgr.isModelInstalled("openai_whisper-base.en"))
    }
}
