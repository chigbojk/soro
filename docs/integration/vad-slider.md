# VAD Sensitivity Slider — Integration Notes

Task key: **vad-slider**

## Files changed

| File | Change |
|---|---|
| `Soro/Models/Preferences.swift` | Added `var vadSensitivity: Double?` (optional for §6 JSON compat, default 0.5 in `.default`) |
| `Soro/Core/Transcription/TranscriptionService.swift` | Added `vadSensitivity: () -> Double` closure to `WhisperKitTranscriptionService.init`; added static `decodeOptionsFor(sensitivity:)` mapping; wired into `transcribe()` |
| `Soro/UI/Dashboard/SettingsView.swift` | Added `VoiceDetectionSection` card with a 0–1 slider; inserted between Transcription and Cleanup sections |
| `Soro/App/AppState.swift` | Passed `vadSensitivity` closure to `WhisperKitTranscriptionService` |
| `Soro/SoroTests/VADSensitivityTests.swift` | 13 unit tests covering the mapping function (extremes, midpoint, boundary, clamping, monotonicity) + preferences persistence |

## Sensitivity → decode option mapping

`WhisperKitTranscriptionService.decodeOptionsFor(sensitivity:)` — a pure static function:

```swift
static func decodeOptionsFor(sensitivity: Double) -> (noSpeechThreshold: Float, useVAD: Bool) {
    let clamped = min(1.0, max(0.0, sensitivity))
    let noSpeechThreshold = Float(0.8 - clamped * 0.5)
    let useVAD = clamped < 0.8
    return (noSpeechThreshold, useVAD)
}
```

| sensitivity | noSpeechThreshold | VAD chunking |
|---|---|---|
| 0.0 (aggressive) | 0.80 | ON |
| 0.5 (default midpoint) | 0.55 | ON |
| 0.8 (boundary) | 0.40 | OFF |
| 1.0 (keep everything) | 0.30 | OFF |

Higher sensitivity → lower threshold → fewer segments dropped → short ad-libs like "Yo." survive.

## AppState wiring (already applied)

In `AppState.init`, replace the plain `WhisperKitTranscriptionService(paths: paths)` call with:

```swift
let transcription = WhisperKitTranscriptionService(
    paths: paths,
    vadSensitivity: { [weak prefs] in prefs?.prefs.vadSensitivity ?? 0.5 }
)
```

This was applied in the same commit. The closure captures `prefs` weakly so AppState can dealloc
normally; it reads `vadSensitivity ?? 0.5` so old preferences.json files (no key) behave as if
the slider is at the midpoint.

## JSON compatibility

`vadSensitivity` is declared `var vadSensitivity: Double?` (optional). Existing
`preferences.json` files without the key decode to `nil`; the UI falls back to `0.5` via the
`?? 0.5` guard in `VoiceDetectionSection.sensitivity` and `AppState` closure. New saves always
write the key.

## UI placement

The "Voice detection" card appears between Transcription and Cleanup in `SettingsView`.
It uses `SettingsCard` / `SettingsRow` exactly like the surrounding sections.
The slider label reads "Filter silence" (left) … "Keep everything" (right) with a contextual
caption below describing the current effect.
