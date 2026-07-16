# Integration: model-management (curated Whisper + Ollama pickers in Settings)

Task key: **model-management**. Lets the user choose & download both models (Whisper STT,
Ollama cleanup) from curated "sensible defaults" lists in Settings.

## Files changed (my scope)

- `Core/Transcription/ModelManager.swift`
  - New `WhisperModelOption` (id/name/sizeHint/qualityHint).
  - `ModelManager.curatedModels: [WhisperModelOption]` — the curated catalogue (fastest → most
    accurate). **Extend by appending here**; picker, download, install detection all read it.
  - `availableModels` now = `curatedModels.map(\.id)` (unchanged behaviour for old callers).
  - `curatedModel(id:)` lookup helper.
  - `selectedModel(from prefs:)` → resolves `prefs.whisperModel`, falling back to `defaultModel`
    when empty/unknown. **This is the hook AppState should use (see wiring below).**
- `Core/Cleanup/OllamaClient.swift`
  - New `OllamaModelOption` (id/label/hint).
  - `OllamaClient.curatedModels` — `llama3.2:3b` (Fast), `qwen2.5:7b` (Balanced), `llama3.1:8b` (HQ).
  - Pure helpers: `normalizeTag`, `isInstalled(_:in:)`, `parseTagNames(from:)`, `parsePullProgress(from:)`.
  - `installedModels()` now delegates to `parseTagNames`.
  - New `pullModel(_:progress:)` — streams `POST /api/pull`, reports (fraction, status), returns
    success. Graceful (`false` on any error), NO timeout (caller cancels by dropping the Task).
- `UI/Dashboard/SettingsView.swift` — `TranscriptionSection` + `CleanupSection` rebuilt as
  per-model row lists (radio select + size/quality hints + Installed / Download|Pull / Active +
  progress). Two new injected closures each, all with safe defaults so the view compiles standalone.
- `Models/Preferences.swift` — `whisperModel` **default changed** `openai_whisper-base.en` →
  `openai_whisper-small.en` to agree with `ModelManager.defaultModel` (they were inconsistent;
  warm-up already used small.en). `ollamaModel` unchanged (already `llama3.2:3b`). No new key was
  needed — `whisperModel` already exists and is the "selectedWhisperModel" pref.
- Tests: `SoroTests/ModelManagementTests.swift` (new, 19 tests). Updated one assertion in
  `SettingsViewTests.testDefaultWhisperModel*` to expect small.en.

## REQUIRED wiring in DashboardWindow (OUT of my scope — do this to activate the UI)

`SettingsView` gained four injected closures with safe defaults. Wire them in
`DashboardWindow.swift` where `SettingsView(...)` is constructed (currently ~line 78):

```swift
SettingsView(
    transcriptionIsModelReady: { [weak appState] _ in
        appState?.transcription.isModelReady ?? false
    },
    // NEW: per-model on-disk install check
    transcriptionIsModelInstalled: { name in
        ModelManager(paths: .live).isModelInstalled(name)
    },
    transcriptionPrepareModel: { [weak appState] name, progress in
        try await appState?.transcription.prepareModel(name, progress: progress)
    },
    cleanupIsAvailable: { [weak appState] in
        await appState?.cleanup.isAvailable() ?? false
    },
    // NEW: live-installed Ollama tags
    ollamaInstalledModels: {
        await OllamaClient(model: "").installedModels()
    },
    // NEW: streamed pull
    ollamaPull: { tag, progress in
        await OllamaClient(model: tag).pullModel(tag, progress: progress)
    })
```

Without this wiring the sections still render but show everything as "not installed" and the
download/pull buttons no-op (defaults). Build stays green either way.

## REQUIRED wiring so the SELECTED whisper model is the one prepared/used

Today the pipeline uses whatever model was last `prepareModel`'d, self-healing to
`ModelManager.defaultModel` (`TranscriptionService.transcribe`, ~line 153). The warm-up in
`AppState` hardcodes the default. Two one-line changes make the **selected** model authoritative:

1. `App/AppState.swift` warm-up (~line 242), replace:
   ```swift
   let model = ModelManager.defaultModel
   ```
   with:
   ```swift
   let model = ModelManager.selectedModel(from: prefs.prefs)   // reads prefs.whisperModel
   ```
   (`prefs` is the `PreferencesStore` already captured in `init`; capture it into the
   `Task.detached` alongside `paths`/`transcription`.)

2. So a mid-session model switch takes effect without relaunch, `AppState` should re-prepare
   when the pref changes. Simplest: in `App/SoroApp.swift` (where the prepare closure is set,
   ~line 78) nothing changes; instead, after the Settings picker writes `whisperModel`, the next
   dictation's `transcribe()` self-heal already loads `loadedModel` — but that's the *previously*
   loaded one. To honour a fresh selection immediately, have the coordinator/AppState call
   `transcription.prepareModel(ModelManager.selectedModel(from:prefs), progress:)` when
   `whisperModel` changes (e.g. observe `preferencesStore.$prefs` and diff `whisperModel`).
   If you keep it minimal: the selected model is picked up on next app launch via change (1),
   and same-session after the user hits **Download** (which calls `prepareModel(selected)` and
   thus updates `loadedModel`). Document whichever you choose.

## OllamaCleanupService uses prefs.ollamaModel live

`AppState` builds `OllamaClient(model: prefs.prefs.ollamaModel)` once at init (~line 78). If the
`OllamaCleanupService`/`OllamaClient` snapshot the model at construction, a Settings change won't
take effect until relaunch. To make it **live**, have `OllamaCleanupService` read
`prefs.prefs.ollamaModel` per call (e.g. inject a `model: () -> String` closure like the existing
`vadSensitivity`/`automaticEnter` closures, or rebuild the `OllamaClient` per cleanup with the
current pref). Both `OllamaCleanupService` and `AppState` are out of my scope — this is the note.
The Settings picker already persists to `prefs.ollamaModel` (existing key), so once the service
reads it live, selection is honoured with no other change.

## Verification

- `xcodegen generate && xcodebuild -project Soro.xcodeproj -scheme Soro -destination
  'platform=macOS' build` → **BUILD SUCCEEDED**.
- `ModelManagementTests` (19) + `SettingsViewTests` (17) → **36 passed, 0 failures**.
- Live Ollama smoke: `GET /api/tags` returned `llama3.2:3b`; `parseTagNames`/`isInstalled`
  parse it correctly.
