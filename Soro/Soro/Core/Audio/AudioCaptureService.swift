import Foundation
import AVFoundation

/// Full captured audio: 16 kHz mono samples + saved file (brief §3a).
struct CapturedAudio: Sendable {
    let samples: [Float]              // 16kHz mono
    let duration: TimeInterval
    let fileURL: URL?                 // wav/opus on disk (nil if save failed)
}

/// AVAudioEngine capture at 16 kHz mono Float32 (implemented in M2).
protocol AudioCaptureService: AnyObject {
    var levelStream: AsyncStream<Float> { get }        // 0…1 mic level for waveform, ~30Hz
    func start() throws                                 // begins capture + buffering
    func stop() async -> CapturedAudio                  // returns full buffer + saved file
    func cancel()                                       // discard, delete partial file
}

/// Optional live-buffer access for incremental/streaming transcription
/// (task `streaming-transcription`). Kept as an extension with a default so the
/// core `AudioCaptureService` contract is untouched: services that don't support
/// snapshotting report `nil` and the pipeline falls back to single-pass on stop.
extension AudioCaptureService {
    /// A copy of the 16 kHz mono samples accumulated so far, WITHOUT stopping
    /// capture. Returns `nil` for services that can't snapshot in-flight audio.
    /// The concrete `AVAudioEngineCaptureService` overrides this.
    func snapshotSamples() -> [Float]? { nil }
}

/// M1 stub — compiles and no-ops. Real capture arrives in M2.
final class StubAudioCaptureService: AudioCaptureService {
    let levelStream: AsyncStream<Float>
    private let continuation: AsyncStream<Float>.Continuation

    init() {
        var cont: AsyncStream<Float>.Continuation!
        levelStream = AsyncStream { cont = $0 }
        continuation = cont
    }

    func start() throws { /* M2 */ }

    func stop() async -> CapturedAudio {
        CapturedAudio(samples: [], duration: 0, fileURL: nil)
    }

    func cancel() { /* M2 */ }
}

// MARK: - Real capture (M2)

/// Live `AVAudioEngine` input-tap capture. Taps the input node, converts each
/// buffer to 16 kHz mono Float32 with `AVAudioConverter`, accumulates the full
/// recording, and emits a ~30 Hz 0…1 mic level on `levelStream` for the waveform
/// (brief §3a). Every failure path degrades gracefully — start throws, stop/cancel
/// never hang or crash.
final class AVAudioEngineCaptureService: AudioCaptureService {

    enum CaptureError: Error { case engineStartFailed, noInputFormat, converterUnavailable }

    let levelStream: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private let engine = AVAudioEngine()
    private let writer: RecordingWriter
    private let targetSampleRate: Double = 16_000

    /// Serializes access to the accumulating buffer between the audio thread and
    /// stop()/cancel() on the main actor.
    private let lock = NSLock()
    private var samples: [Float] = []
    private var levelAccumulator: [Float] = []        // pending samples for the next level tick
    private var lastLevelEmit = Date.distantPast
    private let levelInterval: TimeInterval = 1.0 / 30.0

    private var isRunning = false

    init(writer: RecordingWriter = RecordingWriter()) {
        self.writer = writer
        var cont: AsyncStream<Float>.Continuation!
        levelStream = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { cont = $0 }
        levelContinuation = cont
    }

    func start() throws {
        guard !isRunning else { return }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        levelAccumulator.removeAll(keepingCapacity: true)
        lastLevelEmit = .distantPast
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputFormat
        }

        // Target format: 16 kHz mono Float32, non-interleaved (whisper wants this).
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw CaptureError.converterUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, outFormat: outFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed
        }
        isRunning = true
    }

    private func process(buffer: AVAudioPCMBuffer,
                         converter: AVAudioConverter,
                         outFormat: AVAudioFormat) {
        // Estimate output capacity from the sample-rate ratio (+slack).
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            return
        }

        var fed = false
        let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData?[0] else { return }

        let frames = Int(outBuffer.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: frames))

        lock.lock()
        samples.append(contentsOf: chunk)
        levelAccumulator.append(contentsOf: chunk)
        let now = Date()
        var levelToEmit: Float?
        if now.timeIntervalSince(lastLevelEmit) >= levelInterval {
            levelToEmit = AudioMath.micLevel(rms: AudioMath.rms(levelAccumulator))
            levelAccumulator.removeAll(keepingCapacity: true)
            lastLevelEmit = now
        }
        lock.unlock()

        if let level = levelToEmit {
            levelContinuation.yield(level)
        }
    }

    /// A thread-safe copy of the samples accumulated so far, without stopping
    /// capture. Used by the streaming transcriber to grab the in-progress buffer
    /// while recording continues (task `streaming-transcription`).
    func snapshotSamples() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    func stop() async -> CapturedAudio {
        teardown()

        lock.lock()
        let captured = samples
        lock.unlock()

        let duration = Double(captured.count) / targetSampleRate
        // Persist off the main actor; degrade to nil fileURL on failure.
        let url = writer.write(samples: captured, sampleRate: Int(targetSampleRate))
        return CapturedAudio(samples: captured, duration: duration, fileURL: url)
    }

    func cancel() {
        teardown()
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        levelAccumulator.removeAll(keepingCapacity: false)
        lock.unlock()
        // Nothing persisted yet on cancel, so no file to delete.
    }

    private func teardown() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        levelContinuation.yield(0)      // waveform settles to flat
    }
}
