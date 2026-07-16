import Foundation
import Combine

/// The dictation state machine (brief §3). Equatable so views/tests can assert.
enum DictationState: Equatable {
    case idle
    case recording(locked: Bool)
    case transcribing
    case inserting
    case done
    case error(String)
}

/// The only component that touches everything. In M1 the state transitions are
/// wired but each pipeline step is delegated to the (stub) service protocols; the
/// real capture→whisper→glossary→cleanup→insert→persist chain fills in over M2–M8.
@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: DictationState = .idle

    private let audio: AudioCaptureService
    private let transcription: TranscriptionService
    private let cleanup: CleanupService
    private let insertion: InsertionService
    private let glossary: GlossaryStore
    private let transcripts: TranscriptStore
    private let stats: StatsStore
    private let autoDict: AutoDictionaryStore
    private let personalization: PersonalizationStore
    private let preferences: PreferencesStore
    private let styleSamples: StyleSampleStore
    private let recordingWriter: RecordingWriter

    /// Optional transient-toast sink (brief § toasts-tripletap). Decoupled: the coordinator
    /// emits high-level events and the (optional) `ToastCenter` renders them. Defaults to a
    /// detached, no-op center so the pipeline works headless and in tests without wiring.
    private let toasts: ToastCenter

    /// Id of the currently-shown sticky "Transcribing…" toast, so we can replace/dismiss it
    /// when the pipeline resolves.
    private var transcribingToastID: UUID?

    /// Frontmost-app context captured at record start (§5, App C).
    private var contextSnapshot: ContextSnapshot?
    private var recordTask: Task<Void, Never>?

    /// Live incremental transcriber for the current recording. Created at record
    /// start when the environment supports it (model ready + snapshotable audio),
    /// so long clips are largely transcribed DURING recording and only a short
    /// tail remains on stop (task `streaming-transcription`). `nil` → single-pass.
    private var streamingTranscriber: StreamingTranscriber?

    /// Glossary-derived initial prompt captured at record start (reused for both
    /// the streaming chunks and the final-pipeline transcribe so they stay
    /// consistent).
    private var recordInitialPrompt: String?

    init(audio: AudioCaptureService,
         transcription: TranscriptionService,
         cleanup: CleanupService,
         insertion: InsertionService,
         glossary: GlossaryStore,
         transcripts: TranscriptStore,
         stats: StatsStore,
         autoDict: AutoDictionaryStore,
         personalization: PersonalizationStore,
         preferences: PreferencesStore,
         styleSamples: StyleSampleStore = StyleSampleStore(),
         recordingWriter: RecordingWriter = RecordingWriter(),
         toasts: ToastCenter = ToastCenter()) {
        self.audio = audio
        self.transcription = transcription
        self.cleanup = cleanup
        self.insertion = insertion
        self.glossary = glossary
        self.transcripts = transcripts
        self.stats = stats
        self.autoDict = autoDict
        self.personalization = personalization
        self.preferences = preferences
        self.styleSamples = styleSamples
        self.recordingWriter = recordingWriter
        self.toasts = toasts
    }

    // MARK: Control (called by HotkeyManager gestures)

    func beginRecording(locked: Bool) {
        guard case .idle = state else { return }
        contextSnapshot = ContextDetector.snapshot()
        do {
            try audio.start()
            state = .recording(locked: locked)
            if locked { stats.markHandsFreeUsed() }
            // Start tone — honoring prefs (M9 §3).
            if preferences.prefs.audioRecordingSounds { DictationSounds.playStart() }
            startStreamingTranscriber()
        } catch {
            state = .error("audio: \(error.localizedDescription)")
        }
    }

    /// Spin up incremental transcription for the in-flight recording. Best-effort:
    /// only when the model is already loaded (we don't want to trigger a first-time
    /// download mid-recording) and the audio service can hand out a live buffer
    /// snapshot. On any unmet precondition we simply leave `streamingTranscriber`
    /// nil and the pipeline does its normal single-pass on stop.
    private func startStreamingTranscriber() {
        streamingTranscriber = nil
        // Capture the glossary prompt now so streaming chunks and the final pass
        // are biased identically.
        recordInitialPrompt = GlossaryPass.buildInitialPrompt(from: glossary.enabledTerms())
        guard transcription.isModelReady else { return }
        // Snapshot support is opt-in via the AudioCaptureService extension; a nil
        // return means "no live buffer" → skip streaming.
        guard audio.snapshotSamples() != nil else { return }

        let audioRef = audio
        let streamer = StreamingTranscriber(
            transcription: transcription,
            snapshot: { [weak audioRef] in audioRef?.snapshotSamples() },
            options: .init(language: preferences.prefs.appLanguage,
                           initialPrompt: recordInitialPrompt))
        streamer.start()
        streamingTranscriber = streamer
    }

    /// Upgrade an already-running push-to-talk session to locked, in place, without
    /// stopping/restarting capture (M4: `began` then `lockOn` on the same session).
    func markLocked() {
        guard case .recording = state else { return }
        state = .recording(locked: true)
        stats.markHandsFreeUsed()
    }

    func endRecording() {
        guard case .recording = state else { return }
        // Stop tone — honoring prefs (M9 §3).
        if preferences.prefs.audioRecordingSounds { DictationSounds.playStop() }
        state = .transcribing
        // Sticky "Transcribing…" toast — stays until the pipeline resolves it (§ toasts-tripletap).
        transcribingToastID = toasts.showTranscribing()
        recordTask = Task { await runPipeline() }
    }

    func cancelRecording() {
        guard case .recording = state else { return }
        audio.cancel()
        streamingTranscriber?.cancel()
        streamingTranscriber = nil
        recordTask?.cancel()
        // Clear any in-flight "Transcribing…" toast (cancel normally happens before it appears,
        // but be safe if a cancel races the pipeline).
        if let id = transcribingToastID { toasts.dismiss(id); transcribingToastID = nil }
        state = .idle
    }

    func pasteLast() {
        Task { _ = await insertion.reinsertLast() }
    }

    // MARK: Pipeline (M1: wired through stub services)

    private func runPipeline() async {
        // Detach the live streamer before stopping capture so we can finalize it
        // against the full buffer.
        let streamer = streamingTranscriber
        streamingTranscriber = nil

        let captured = await audio.stop()
        let enabledTerms = glossary.enabledTerms()
        let snap = contextSnapshot ?? ContextDetector.snapshot()
        // Glossary terms are tokenized into the initial prompt to bias recognition
        // (§3b/§3c). Captured at record start; recompute defensively if missing.
        let initialPrompt = recordInitialPrompt
            ?? GlossaryPass.buildInitialPrompt(from: enabledTerms)
        recordInitialPrompt = nil

        // Transcribe. Prefer the incremental streaming result (only the short tail
        // was left to process on stop). If streaming is unavailable, failed, or
        // produced nothing, fall back to a full single-pass — never a regression.
        var raw: String
        do {
            if let streamed = await streamer?.finish(fullSamples: captured.samples) {
                raw = streamed
            } else {
                raw = try await transcription.transcribe(
                    captured,
                    language: preferences.prefs.appLanguage,
                    initialPrompt: initialPrompt)
            }
        } catch {
            raw = Transcript.errorSentinel
        }

        // Glossary passes (§3c): literal replacements, then case-correction of known terms.
        if raw != Transcript.errorSentinel {
            raw = glossary.applyReplacements(to: raw)
            raw = GlossaryPass.caseCorrect(text: raw, terms: enabledTerms)
        }

        // Cleanup + style pass (never throws; falls back to raw).
        var finalText = raw
        if raw != Transcript.errorSentinel, preferences.prefs.cleanupEnabled {
            let style = personalization.styleFor(snap.context)
            let ctx = CleanupContext(
                appName: snap.appName,
                bundleId: snap.bundleId,
                context: snap.context,
                messagingStyle: style.messaging,
                scribeStyle: style.scribe,
                personalTweak: style.tweak,
                glossaryTerms: enabledTerms,
                styleSamples: styleSamples.recent(3, for: snap.context),
                isCodeEditor: snap.isCodeEditor)
            finalText = await cleanup.cleanup(raw, context: ctx).text
        }

        // Insert at cursor.
        state = .inserting
        var inserted = false
        if finalText != Transcript.errorSentinel, !finalText.isEmpty {
            let result = await insertion.insert(finalText)
            switch result {
            case .pasted, .typed: inserted = true
            case .failedSecureInput, .failed: inserted = false
            }
        }

        // Privacy mode: delete the recording file and null the stored audioURL so no
        // audio persists after transcription (§6, M2 note).
        var audioURL = captured.fileURL
        if preferences.prefs.privacyMode {
            if let url = audioURL { recordingWriter.delete(url) }
            audioURL = nil
        }

        // Persist record + update stats/auto-dictionary/style memory.
        let record = Transcript(
            text: finalText,
            audioURL: audioURL,
            recordingDuration: captured.duration)
        transcripts.add(record)
        if finalText != Transcript.errorSentinel {
            stats.recordDictation(words: wordCount(finalText), duration: captured.duration,
                                  appName: snap.appName, bundleId: snap.bundleId, text: finalText)
            // Only learn from output that actually landed in the target app.
            if inserted {
                autoDict.observe(transcript: finalText)
                styleSamples.append(finalText, for: snap.context)
            }
        }

        // Success tone when text was actually inserted (M9 §3).
        if inserted, preferences.prefs.audioRecordingSounds {
            DictationSounds.playSuccess()
        }

        // Resolve the sticky "Transcribing…" toast into a terminal outcome (§ toasts-tripletap):
        // success flash when text landed, a countdown error toast on failure (transcription
        // error sentinel, empty result, or an insertion failure). Replace-in-place so it keeps
        // its stack slot rather than popping a second toast.
        resolveTranscribingToast(succeeded: inserted, finalText: finalText)

        state = .done
        // Brief done flash → idle.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if case .done = state { state = .idle }
    }

    /// Turns the sticky "Transcribing…" toast into a terminal Pasted/Failed toast (or a
    /// standalone one if it already went away). Failure covers the error sentinel, an empty
    /// result, and insertion failures — all cases where nothing useful reached the cursor.
    private func resolveTranscribingToast(succeeded: Bool, finalText: String) {
        let failed = !succeeded
            || finalText == Transcript.errorSentinel
            || finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let terminal: Toast = failed
            ? Toast(message: "Failed to transcribe",
                    systemImage: "exclamationmark.triangle.fill", style: .failure, duration: 3.0)
            : Toast(message: "Pasted",
                    systemImage: "checkmark.circle.fill", style: .success, duration: 1.6)
        if let id = transcribingToastID {
            toasts.replace(id, with: terminal)
        } else {
            toasts.show(terminal)
        }
        transcribingToastID = nil
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
}
