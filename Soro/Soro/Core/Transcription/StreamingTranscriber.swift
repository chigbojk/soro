import Foundation

// MARK: - Pure stitching / dedup (headless-testable)

/// Pure helpers for stitching incrementally-transcribed segments into one
/// transcript. Segments are cut at VAD silence boundaries, so the common case is
/// plain concatenation; the dedup guard defends against the rare case where a
/// segment boundary lands mid-phrase and Whisper re-emits a few boundary words in
/// the next segment (overlap). No AVFoundation / WhisperKit here so this is unit
/// testable without a mic or a model.
enum TranscriptStitcher {

    /// Join two already-transcribed pieces, removing a duplicated word run where
    /// the tail of `left` repeats the head of `right`. Returns the stitched text.
    ///
    /// Matching is case/punctuation-insensitive on a per-word basis. We look for
    /// the longest suffix of `left` (up to `maxOverlapWords`) that equals a prefix
    /// of `right`, and drop that prefix from `right`.
    static func stitch(_ left: String, _ right: String, maxOverlapWords: Int = 6) -> String {
        let l = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if l.isEmpty { return r }
        if r.isEmpty { return l }

        let leftWords = words(l)
        let rightWords = words(r)
        let leftNorm = leftWords.map(normalize)
        let rightNorm = rightWords.map(normalize)

        let maxK = min(maxOverlapWords, min(leftNorm.count, rightNorm.count))
        var overlap = 0
        var k = maxK
        while k >= 1 {
            // last k normalized words of left == first k normalized words of right?
            if Array(leftNorm.suffix(k)) == Array(rightNorm.prefix(k)) {
                overlap = k
                break
            }
            k -= 1
        }

        if overlap == 0 {
            return l + " " + r
        }
        let remaining = rightWords.dropFirst(overlap)
        if remaining.isEmpty { return l }
        return l + " " + remaining.joined(separator: " ")
    }

    /// Reduce an ordered list of transcribed segments to a single transcript,
    /// stitching adjacent pairs (drops empty segments first).
    static func join(_ segments: [String], maxOverlapWords: Int = 6) -> String {
        let parts = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var acc = parts.first else { return "" }
        for next in parts.dropFirst() {
            acc = stitch(acc, next, maxOverlapWords: maxOverlapWords)
        }
        return acc
    }

    // MARK: helpers

    private static func words(_ s: String) -> [String] {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init)
    }

    /// Lowercased, stripped of surrounding punctuation, for word-equality checks.
    private static func normalize(_ w: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = w.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
}

// MARK: - Silence-boundary segmenter (headless-testable)

/// Finds a safe cut point in a rolling 16 kHz mono buffer: the end of a run of
/// low-energy (silence) frames, so a chunk can be committed to transcription
/// without slicing through a word. Pure DSP over `[Float]`; unit-testable.
enum SilenceSegmenter {

    struct Config {
        /// Only consider committing once at least this many samples have piled up.
        var minChunkSamples: Int
        /// Never commit a cut that leaves the buffer with less than this many
        /// samples of context before it (avoids tiny/degenerate chunks).
        var minLeadSamples: Int
        /// A window is "silent" if its RMS is below this (linear amplitude).
        var silenceRMS: Float
        /// Analysis window length in samples (~30 ms at 16 kHz).
        var windowSamples: Int
        /// Require this many consecutive silent windows to treat it as a boundary.
        var minSilentWindows: Int

        static let `default` = Config(
            minChunkSamples: 16_000 * 6,   // ~6 s of new audio before we try to cut
            minLeadSamples: 16_000 * 1,    // keep ≥1 s of speech in a committed chunk
            silenceRMS: 0.012,
            windowSamples: 480,            // 30 ms @ 16 kHz
            minSilentWindows: 6            // ~180 ms of quiet
        )
    }

    /// Given the samples accumulated since the last commit (`pending`), return the
    /// index (relative to `pending`) at which it's safe to cut — i.e. the end of a
    /// trailing-ish silence gap — or `nil` if no good boundary exists yet.
    ///
    /// The returned index is the count of samples to commit; the caller keeps
    /// `pending[index...]` for the next round.
    static func cutPoint(in pending: [Float], config: Config = .default) -> Int? {
        guard pending.count >= config.minChunkSamples else { return nil }
        let win = config.windowSamples
        guard win > 0 else { return nil }

        // Walk windows; track runs of silent windows. We cut at the END of the
        // FIRST silence run that begins at or after minLeadSamples, so the chunk
        // carries a full utterance plus its trailing pause.
        var i = 0
        var runStart: Int? = nil
        var runLen = 0
        var candidate: Int? = nil
        while i + win <= pending.count {
            let rms = AudioMath.rms(pending[i..<(i + win)])
            let silent = rms < config.silenceRMS
            if silent {
                if runStart == nil { runStart = i }
                runLen += 1
            } else {
                if let start = runStart, runLen >= config.minSilentWindows {
                    // Cut in the middle of the silence run for a clean boundary.
                    let mid = start + (runLen * win) / 2
                    if mid >= config.minLeadSamples {
                        candidate = mid
                        break
                    }
                }
                runStart = nil
                runLen = 0
            }
            i += win
        }
        // A trailing silence run that never ended (still quiet at buffer end).
        if candidate == nil, let start = runStart, runLen >= config.minSilentWindows {
            let mid = start + (runLen * win) / 2
            if mid >= config.minLeadSamples { candidate = mid }
        }
        return candidate
    }
}

// MARK: - Live streaming driver

/// Transcribes on-device WHILE recording by periodically committing
/// silence-bounded chunks of the growing buffer to the underlying
/// `TranscriptionService`, then, on `finish`, transcribing only the remaining
/// tail and stitching everything together.
///
/// Perceived latency on stop ≈ the last (short) tail rather than the whole clip,
/// because the bulk of the audio was already transcribed during the pause gaps
/// while the user was still speaking.
///
/// Correctness guarantees:
///  * chunks are cut inside silence, so no word is split across a boundary;
///  * `TranscriptStitcher` dedups any accidental boundary word-overlap;
///  * on ANY error the driver bails and the caller falls back to single-pass
///    over the full buffer — the final text is never worse than today.
///
/// `@unchecked Sendable`: all mutable state is confined to the single serial
/// `Task` created in `start()`; the snapshot closure only reads a locked buffer.
final class StreamingTranscriber: @unchecked Sendable {

    struct Options {
        var language: String?
        var initialPrompt: String?
        /// How often to poll the buffer for a commit opportunity.
        var pollInterval: TimeInterval = 1.5
        var segmenter: SilenceSegmenter.Config = .default
    }

    private let transcription: TranscriptionService
    private let snapshot: @Sendable () -> [Float]?
    private let options: Options

    private let lock = NSLock()
    private var committedSamples = 0          // absolute index into the full buffer
    private var segments: [String] = []       // transcribed committed chunks, in order
    private var failed = false                 // a chunk transcribe threw → give up streaming
    private var pollTask: Task<Void, Never>?

    init(transcription: TranscriptionService,
         snapshot: @escaping @Sendable () -> [Float]?,
         options: Options) {
        self.transcription = transcription
        self.snapshot = snapshot
        self.options = options
    }

    /// Begin polling + committing chunks in the background. Safe to call once.
    func start() {
        guard pollTask == nil else { return }
        let interval = options.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { break }
                if self.hasFailed { break }
                await self.tryCommitChunk()
            }
        }
    }

    private var hasFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    /// Attempt to commit ONE silence-bounded chunk from the current buffer.
    private func tryCommitChunk() async {
        guard let full = snapshot() else { return }
        lock.lock()
        let start = committedSamples
        lock.unlock()
        guard full.count > start else { return }
        let pending = Array(full[start...])
        guard let cut = SilenceSegmenter.cutPoint(in: pending, config: options.segmenter) else {
            return
        }
        let chunk = Array(pending[0..<cut])
        guard !chunk.isEmpty else { return }

        let audio = CapturedAudio(samples: chunk,
                                  duration: Double(chunk.count) / 16_000,
                                  fileURL: nil)
        do {
            let text = try await transcription.transcribe(
                audio, language: options.language, initialPrompt: options.initialPrompt)
            lock.lock()
            segments.append(text)
            committedSamples = start + cut
            lock.unlock()
        } catch {
            // Streaming path is best-effort. On failure, stop committing and let
            // finish() signal the caller to fall back to a full single-pass.
            lock.lock(); failed = true; lock.unlock()
        }
    }

    /// Stop polling and produce the final transcript.
    ///
    /// - Parameter fullSamples: the complete recording (from `audio.stop()`).
    /// - Returns: the stitched streaming result, or `nil` if streaming failed /
    ///   produced nothing and the caller should run its normal single-pass.
    func finish(fullSamples: [Float]) async -> String? {
        pollTask?.cancel()
        pollTask = nil

        lock.lock()
        let didFail = failed
        let start = committedSamples
        var priorSegments = segments
        lock.unlock()

        // If streaming ever failed, or we never committed anything, don't risk a
        // degraded result — tell the caller to do a clean single-pass.
        if didFail { return nil }
        if priorSegments.isEmpty { return nil }

        // Transcribe only the remaining tail (fast: last chunk, not whole clip).
        if fullSamples.count > start {
            let tail = Array(fullSamples[start...])
            if !tail.isEmpty {
                let tailAudio = CapturedAudio(samples: tail,
                                              duration: Double(tail.count) / 16_000,
                                              fileURL: nil)
                do {
                    let tailText = try await transcription.transcribe(
                        tailAudio,
                        language: options.language,
                        initialPrompt: options.initialPrompt)
                    priorSegments.append(tailText)
                } catch {
                    return nil   // fall back rather than drop the tail
                }
            }
        }

        let stitched = TranscriptStitcher.join(priorSegments)
        return stitched.isEmpty ? nil : stitched
    }

    /// Abort streaming (recording cancelled). Idempotent.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }
}
