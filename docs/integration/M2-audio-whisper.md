# M2 — Audio capture + Whisper transcription (integration)

Real implementations for `Core/Audio/` and `Core/Transcription/`. The M1 stubs
(`StubAudioCaptureService`, `StubTranscriptionService`) are left in place and still
compile; `AppState` just needs to swap the two service instances it constructs.

## The one wiring change (AppState.swift)

In `AppState.init(...)`, replace the two stub service constructions:

```swift
// BEFORE (M1)
let audio = StubAudioCaptureService()
let transcription = StubTranscriptionService()

// AFTER (M2)
let audio = AVAudioEngineCaptureService()               // uses RecordingWriter(paths:) internally
let transcription = WhisperKitTranscriptionService(paths: paths)
```

Nothing else changes: both new classes conform to the exact protocols
(`AudioCaptureService`, `TranscriptionService`) already declared in
`docs/CONTRACTS.md`, so `DictationCoordinator`'s init parameters and every call site
(`audio.start()/stop()/cancel()`, `audio.levelStream`, `transcription.prepareModel`,
`transcription.transcribe`) are unchanged.

### Init parameters
- `AVAudioEngineCaptureService(writer: RecordingWriter = RecordingWriter())` — the
  default writer targets `AppPaths.live`. If you want capture to honor a non-default
  `paths` (e.g. tests), pass `AVAudioEngineCaptureService(writer: RecordingWriter(paths: paths))`.
- `WhisperKitTranscriptionService(paths: AppPaths = .live)` — pass the same `paths`
  AppState already threads through so models land under `AppPaths.models`.

## Model preparation (who calls prepareModel)

`WhisperKitTranscriptionService.isModelReady` starts `false`. Something must call
`prepareModel` before the first `transcribe`, or transcribe throws `modelNotReady`
(the coordinator already treats a transcription throw as the `ERROR_TRANSCRIBING`
sentinel path — no hang). Recommended: on first launch / onboarding (M9) and from
Settings' model picker, call:

```swift
try await appState.transcription.prepareModel(ModelManager.defaultModel) { progress in
    // 0…1 — drive onboarding/settings download UI
}
```

- Default model: `ModelManager.defaultModel` == `"openai_whisper-base.en"`.
- Settings dropdown options: `ModelManager.availableModels`.
- Downloaded into `AppPaths.models` (WhisperKit layout:
  `Models/models/argmaxinc/whisperkit-coreml/<name>`). `ModelManager(paths:).isModelInstalled(name)`
  reports presence for a "download vs ready" indicator.
- `prepareModel` is idempotent — re-calling with the already-loaded model returns `1.0`
  immediately; calling with a different name swaps models.

## Behavior notes for downstream milestones

- **Waveform (M5):** `levelStream` is an `AsyncStream<Float>` yielding 0…1 values at
  ~30 Hz while recording, and yields a final `0` on stop/cancel so the bar settles.
  Uses a dBFS mapping (-60…0) so whisper-quiet input still moves the meter (brief §5A).
- **CapturedAudio:** `samples` are 16 kHz mono Float32; `fileURL` is the persisted
  `Recordings/recording_<ISO8601>.wav` (colons → `-` for filesystem safety) or `nil`
  if the disk write failed. Privacy mode (delete audio) is the coordinator's job:
  after transcription, call `RecordingWriter(paths:).delete(url)` and null the
  transcript's `audioURL`.
- **initialPrompt:** glossary terms passed as `initialPrompt` are tokenized and fed as
  WhisperKit `promptTokens` to bias recognition (brief §3b/§3c).
- **Failure paths:** `start()` throws (`CaptureError`) if the engine/converter can't
  init (e.g. no mic permission) — coordinator should catch and surface, never hang.
  `stop()`/`cancel()` never throw.

## Permissions
Live capture needs the microphone grant (Info.plist `NSMicrophoneUsageDescription`
already present). Cannot be tested headless — covered by manual App D check #2/#4.

## project.yml
Added the WhisperKit SPM package (`https://github.com/argmaxinc/WhisperKit`, resolves
to 0.18.0) as a dependency of the `Soro` target. `project.yml` and the pinned
`Package.resolved` (under `Soro.xcodeproj/project.xcworkspace/xcshareddata/`) are
committed; run `xcodegen generate` after pulling.
