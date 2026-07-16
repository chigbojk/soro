# Streaming (incremental) transcription — `streaming-transcription`

## Problem
Single-pass transcription ran only on stop, so wall-clock latency scaled O(N) with
clip length. A 4-minute clip meant a long wait AFTER releasing the hotkey.

## Approach chosen
**Silence-boundary rolling chunking** (not a WhisperKit native stream — WhisperKit
1.0's `transcribe(audioArray:)` is single-pass and exposes no incremental callback
on that path). While recording, a background poller snapshots the growing 16 kHz
buffer, finds a safe cut point *inside a VAD silence gap*, and commits that chunk to
`transcription.transcribe(...)`. Cutting in silence means no word is ever split, so
stitching committed chunks is plain concatenation. A token-level dedup guard
(`TranscriptStitcher`) additionally removes any accidental boundary word-overlap.

On stop, only the **remaining tail** (audio since the last committed silence gap) is
transcribed, then everything is stitched. Perceived latency ≈ last tail (seconds),
not the whole clip.

Falls back to the existing single-pass whenever streaming is unavailable, failed, or
produced nothing — correctness never regresses.

## Files changed (scope only)
- `Core/Audio/AudioCaptureService.swift`
  - Protocol extension `snapshotSamples() -> [Float]?` default `nil` (contract intact).
  - `AVAudioEngineCaptureService.snapshotSamples()` returns a locked copy of the
    in-flight buffer WITHOUT stopping capture. No change to `start/stop/cancel`.
- `Core/Transcription/StreamingTranscriber.swift` (NEW)
  - `enum TranscriptStitcher` — pure `stitch`/`join` with word-level, case- and
    punctuation-insensitive overlap dedup (`maxOverlapWords` default 6).
  - `enum SilenceSegmenter` — pure DSP `cutPoint(in:config:)` over `[Float]`;
    finds the mid-point of a silence run ≥ `minSilentWindows` once ≥ `minChunkSamples`
    (~6 s) accumulated and past `minLeadSamples` (~1 s). Uses `AudioMath.rms`.
  - `final class StreamingTranscriber` (`@unchecked Sendable`) — drives the
    poll→commit loop; `start()`, `finish(fullSamples:) -> String?`, `cancel()`.
- `Core/Pipeline/DictationCoordinator.swift`
  - `beginRecording` → `startStreamingTranscriber()`: only when
    `transcription.isModelReady` AND `audio.snapshotSamples() != nil` (else nil → single-pass).
    Captures the glossary `initialPrompt` once so streaming chunks and the final pass are biased identically.
  - `runPipeline`: detaches the streamer, `await audio.stop()`, then prefers
    `streamer.finish(fullSamples:)`; on nil, runs the original single-pass
    `transcription.transcribe(captured, …)`. All downstream steps
    (glossary → cleanup → insert → persist → toasts → stats) unchanged.
  - `cancelRecording` cancels the streamer.

## State-machine / contract impact
None. `DictationState`, public methods, toast/glossary/cleanup/persist steps, and all
service protocols are unchanged. `AudioCaptureService` gained only an extension method
with a default, so existing conformers (incl. `StubAudioCaptureService`) still compile
and behave identically (they report no snapshot → single-pass).

## Preconditions for streaming to engage (else graceful single-pass)
1. Whisper model already loaded at record start (we never trigger a first download mid-record).
2. Audio service supports live snapshots (`AVAudioEngineCaptureService` does; stub does not).
3. Clip long enough to contain ≥1 committable silence-bounded chunk (~≥6 s with a pause).
   Short clips just do single-pass — same as before, already fast.

## Expected latency improvement
- Before: stop-latency ≈ transcribe(whole clip) → grows with duration.
- After: stop-latency ≈ transcribe(last tail since final silence gap), typically a few
  seconds regardless of total length. A 4-minute clip with normal sentence pauses gets
  the bulk transcribed during the pauses while speaking; only the final utterance's
  audio remains on stop. Improvement scales with clip length (largest win on long clips).

## Accuracy tradeoffs
- Chunks are cut in silence, so no cross-boundary word loss. Each chunk is a complete
  utterance run, transcribed with the SAME decode options (VAD + fallback guards +
  glossary prompt) as single-pass, so per-chunk accuracy matches.
- Whisper loses some cross-sentence language-model context at chunk boundaries; because
  boundaries are sentence/pause gaps this is minimal. The `TranscriptStitcher` dedup
  prevents duplicated boundary words if a chunk edge slightly overlaps.
- Any anomaly (chunk transcribe throws, nothing committed) → single-pass fallback, so
  the final pasted text is never worse than the pre-change behavior.

## Tests
`SoroTests/StreamingTranscriberTests.swift` (19 cases, headless, no mic/model):
stitch concat, empty handling, single/multi-word overlap dedup, case/punct-insensitive
overlap, subsumed-right, max-overlap bound, `join` filtering + 3-segment stitch;
`SilenceSegmenter` short-buffer/no-gap/trailing-silence/min-lead/mid-silence cases.
Build + these tests + existing `VADSensitivityTests`/`AudioTests` all pass.
