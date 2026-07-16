# M6 — Glossary Pass + Auto-Learn Integration Notes

## Files added / modified

| File | Status | Owner |
|---|---|---|
| `Soro/Core/Cleanup/GlossaryPass.swift` | New | M6 |
| `Soro/Stores/AutoDictionaryStore.swift` | Modified | M6 |
| `SoroTests/GlossaryPassTests.swift` | New | M6 |

## How to wire into AppState / DictationCoordinator

### 1. GlossaryPass — no instantiation needed (static enum)

`GlossaryPass` is a static utility enum. Call its methods directly from `DictationCoordinator`.

**In `DictationCoordinator.endRecording()`, after `GlossaryStore.applyReplacements`:**

```swift
// 1. Case-correct known terms in the transcript
let enabledTerms = glossaryStore.enabledTerms()
let cased = GlossaryPass.caseCorrect(text: replacedTranscript, terms: enabledTerms)

// 2. Forward cased text to CleanupService
let cleanupContext = CleanupContext(
    ...
    glossaryTerms: enabledTerms,
    ...
)
let (cleanedText, wasCleaned) = await cleanupService.cleanup(cased, context: cleanupContext)
```

**In `TranscriptionService.transcribe(_:language:initialPrompt:)`:**

The caller (`DictationCoordinator`) should compute the initial prompt once at pipeline start:

```swift
let initialPrompt = GlossaryPass.buildInitialPrompt(from: glossaryStore.enabledTerms())
let rawTranscript = try await transcriptionService.transcribe(audio,
                                                              language: prefs.selectedLanguage,
                                                              initialPrompt: initialPrompt)
```

### 2. AutoDictionaryStore — inject glossary closure

`AutoDictionaryStore` has an optional `isInGlossary: ((String) -> Bool)?` closure. Wire it in `AppState` after both stores are initialised:

```swift
// In AppState.init() or wherever stores are composed:
autoDictionaryStore.isInGlossary = { [weak glossaryStore] lowercasedWord in
    guard let store = glossaryStore else { return false }
    return store.enabledTerms().contains { $0.lowercased() == lowercasedWord }
}
```

**Call `observe` after every successful dictation in `DictationCoordinator.endRecording()`:**

```swift
// After insertion succeeds, update auto-dictionary with the final cleaned text:
autoDictionaryStore.observe(transcript: cleanedText)
```

### 3. DictionaryView — AutoDictionaryStore stub replacement

`AppState` currently has a stub `AutoDictionaryStore`. No replacement of the class itself is needed — the M6 changes are backward-compatible additions (new `isInGlossary` closure property, enhanced heuristics). The existing `AutoDictionaryStore(paths:)` init signature is unchanged.

Wire the store into `DictionaryView` via `@EnvironmentObject AutoDictionaryStore` (already specified in CONTRACTS.md).

### 4. PromptBuilder — glossaryTerms pass-through

`CleanupContext.glossaryTerms: [String]` (existing field) carries `GlossaryStore.enabledTerms()` to `PromptBuilder`. The M7 agent will embed them into the Ollama system prompt as `[GLOSSARY_TERMS]` (Appendix B). No M6 changes required to `PromptBuilder` — just ensure the field is populated.

## Summary of new public API

```swift
// GlossaryPass (Core/Cleanup/GlossaryPass.swift)
enum GlossaryPass {
    static func buildInitialPrompt(from enabledTerms: [String]) -> String
    static func caseCorrect(text: String, terms: [String]) -> String
}

// AutoDictionaryStore (Stores/AutoDictionaryStore.swift) — additions
var isInGlossary: ((String) -> Bool)?  // optional closure; set by AppState
// existing contract methods unchanged:
func observe(transcript: String)
func suggestions() -> [String]
func dismiss(_ word: String)
```

No changes to `GlossaryStore.applyReplacements` — that method is owned by the existing skeleton and must not be modified.
