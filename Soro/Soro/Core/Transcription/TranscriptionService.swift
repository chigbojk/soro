import Foundation

/// On-device transcription — WhisperKit preferred (brief App A). Implemented in M2.
protocol TranscriptionService: AnyObject {
    var isModelReady: Bool { get }
    func prepareModel(_ name: String, progress: @escaping (Double) -> Void) async throws
    func transcribe(_ audio: CapturedAudio, language: String?, initialPrompt: String?) async throws -> String
}

/// M1 stub — reports not ready and returns an empty string. Real STT arrives in M2.
final class StubTranscriptionService: TranscriptionService {
    private(set) var isModelReady: Bool = false

    func prepareModel(_ name: String, progress: @escaping (Double) -> Void) async throws {
        progress(1.0)
        isModelReady = true
    }

    func transcribe(_ audio: CapturedAudio, language: String?, initialPrompt: String?) async throws -> String {
        ""
    }
}

// MARK: - Real transcription (M2, WhisperKit)

import WhisperKit

/// On-device STT via WhisperKit (brief App A). Default model
/// `openai_whisper-base.en`, stored under `AppPaths.models`. Loads lazily via
/// `prepareModel` (with progress), then `transcribe` runs Core ML / Metal.
///
/// `isModelReady` is safe to read from any thread; the WhisperKit instance is
/// only touched inside the async methods.
final class WhisperKitTranscriptionService: TranscriptionService, @unchecked Sendable {

    enum TranscribeError: Error { case modelNotReady, noAudio }

    private let paths: AppPaths
    private let stateLock = NSLock()
    private var _isModelReady = false
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    /// Returns the current VAD sensitivity (0.0 = aggressive filtering, 1.0 = keep everything).
    /// Injected as a closure so this service does not import PreferencesStore.
    /// Default: { 0.5 } (midpoint).
    private let vadSensitivity: () -> Double

    var isModelReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isModelReady
    }

    init(paths: AppPaths = .live, vadSensitivity: @escaping () -> Double = { 0.5 }) {
        self.paths = paths
        self.vadSensitivity = vadSensitivity
    }

    // MARK: - VAD / decode-option mapping

    /// Maps a sensitivity value (0.0…1.0) to WhisperKit DecodingOptions fields that
    /// control how aggressively silence and low-quality segments are filtered:
    ///
    ///   sensitivity → 0.0 (aggressive)  : noSpeechThreshold 0.8, VAD chunking ON
    ///   sensitivity → 0.5 (midpoint)    : noSpeechThreshold 0.6, VAD chunking ON
    ///   sensitivity → 1.0 (keep all)    : noSpeechThreshold 0.3, VAD chunking OFF
    ///
    /// The linear interpolation range for noSpeechThreshold runs *inversely*:
    ///   higher sensitivity → lower threshold → fewer segments dropped.
    static func decodeOptionsFor(sensitivity: Double) -> (noSpeechThreshold: Float, useVAD: Bool) {
        let clamped = min(1.0, max(0.0, sensitivity))
        // noSpeechThreshold interpolated from 0.8 (aggressive) down to 0.3 (permissive)
        let noSpeechThreshold = Float(0.8 - clamped * 0.5)
        // Disable VAD chunking above 0.8 so ultra-short clips aren't over-segmented
        let useVAD = clamped < 0.8
        return (noSpeechThreshold, useVAD)
    }

    /// Downloads (if needed) and loads the named model. Progress is a coarse 0…1
    /// derived from WhisperKit's model-download progress plus a load step.
    func prepareModel(_ name: String, progress: @escaping (Double) -> Void) async throws {
        // Already loaded this exact model → done.
        stateLock.lock()
        let alreadyLoaded = _isModelReady && loadedModel == name
        stateLock.unlock()
        if alreadyLoaded { progress(1.0); return }

        progress(0.0)

        let modelFolder = paths.models   // ~/…/Models/
        try? FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

        // Build WhisperKit without auto-loading so we control download + progress.
        let config = WhisperKitConfig(
            model: name,
            downloadBase: modelFolder,
            modelFolder: nil,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)

        // Resolve/download the model repo into our Models dir.
        // Retried once: HubApi can fail moving a finished download into a nested
        // folder (e.g. <model>.mlmodelc/weights/) it didn't create — the first
        // attempt leaves the directory tree behind, so a second pass completes.
        let folder: URL
        do {
            folder = try await Self.downloadModel(name, into: modelFolder, progress: progress)
        } catch {
            folder = try await Self.downloadModel(name, into: modelFolder, progress: progress)
        }
        kit.modelFolder = folder

        progress(0.9)
        try await kit.loadModels()
        progress(1.0)

        stateLock.lock()
        whisperKit = kit
        loadedModel = name
        _isModelReady = true
        stateLock.unlock()
    }

    private static func downloadModel(
        _ name: String, into base: URL, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: name,
            downloadBase: base,
            useBackgroundSession: false,
            from: "argmaxinc/whisperkit-coreml"
        ) { p in
            progress(min(0.9, p.fractionCompleted * 0.9))
        }
    }

    func transcribe(_ audio: CapturedAudio, language: String?, initialPrompt: String?) async throws -> String {
        stateLock.lock()
        var kit = whisperKit
        var ready = _isModelReady
        let lastModel = loadedModel
        stateLock.unlock()

        // Self-heal: if the model isn't loaded yet (launch warm-up skipped/failed,
        // or the download finished after launch), prepare it now instead of failing
        // the dictation. prepareModel is idempotent and no-ops when already loaded.
        if !ready || kit == nil {
            try await prepareModel(lastModel ?? ModelManager.defaultModel) { _ in }
            stateLock.lock()
            kit = whisperKit
            ready = _isModelReady
            stateLock.unlock()
        }
        guard ready, let kit else { throw TranscribeError.modelNotReady }
        guard !audio.samples.isEmpty else { throw TranscribeError.noAudio }

        var options = DecodingOptions()
        options.language = language          // nil → WhisperKit auto/en per model
        // Start greedy, but allow temperature fallback so a garbled/hallucinated
        // decode is retried instead of pasted verbatim.
        options.temperature = 0
        options.temperatureFallbackCount = 5
        options.temperatureIncrementOnFallback = 0.2
        // Hallucination guards: reject repetitive / low-confidence / silence decodes.
        options.compressionRatioThreshold = 2.4   // repetition detector
        options.logProbThreshold = -1.0           // low-confidence → fallback
        // VAD sensitivity mapping: read current preference value and derive thresholds.
        let (noSpeechThreshold, useVAD) = Self.decodeOptionsFor(sensitivity: vadSensitivity())
        options.noSpeechThreshold = noSpeechThreshold
        options.suppressBlank = true
        options.withoutTimestamps = true
        // VAD chunking trims leading/trailing silence and splits on speech gaps —
        // the single biggest accuracy win on short, real-world dictation clips.
        // Disabled at high sensitivity so short/quiet clips (e.g. "Yo.") survive.
        options.chunkingStrategy = useVAD ? .vad : ChunkingStrategy.none
        // Bias recognition toward glossary terms/jargon via a conditioning prompt.
        if let prompt = initialPrompt, !prompt.isEmpty, let tokenizer = kit.tokenizer {
            options.usePrefillPrompt = true
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let results = try await kit.transcribe(
            audioArray: audio.samples,
            decodeOptions: options
        )

        let text = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}
