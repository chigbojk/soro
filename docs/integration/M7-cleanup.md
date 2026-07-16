# M7 — Ollama Cleanup + Style Pass (integration)

Milestone key: **M7-cleanup**. Scope: `Soro/Soro/Core/Cleanup/` (+ tests).

## What shipped

- `OllamaClient` (struct) — `URLSession` client, `127.0.0.1:11434` only. `isReachable()`
  (1.5s), `installedModels()`, `generate(system:user:)` via `POST /api/chat`, `stream:false`,
  `temperature:0.2`, 4s hard timeout. Default model `llama3.2:3b`.
- `PromptBuilder` — Appendix-B system prompt verbatim; `systemPrompt(for:)`, `userPrompt(rawTranscript:)`,
  `fullPrompt(for:rawTranscript:)`.
- `OllamaCleanupService: CleanupService` — real impl replacing `StubCleanupService`. Never throws;
  on unavailable/timeout/error/empty-output returns `(raw, false)`. Defensive `sanitize` strips
  model preamble, wrapping quotes (incl. smart quotes), and code fences.
- `ContextDetector` — unchanged from M1 (already matches §5 map); verified by tests.
- `StyleSampleStore` (new, **not** an `ObservableObject`, thread-safe via `NSLock`) — per-context
  ring buffer (capacity 5) of accepted outputs, persisted to
  `Preferences/style_samples.json`. `append(_:for:)`, `recent(_:for:)` (default 3).

`CleanupService` protocol, `CleanupContext`, and `StubCleanupService` signatures are **unchanged**
(contract-stable). `AppPaths` was **not** edited — `StyleSampleStore` derives its file path from the
existing `paths.preferences` directory.

## Exactly what AppState should change

In `Soro/Soro/App/AppState.swift`, replace the stub cleanup service:

```swift
// was:
let cleanup = StubCleanupService()
// becomes:
let cleanup = OllamaCleanupService(
    client: OllamaClient(model: preferences.prefs.ollamaModel))  // see note below
```

`OllamaCleanupService()` has a zero-arg init that uses the default model `llama3.2:3b`; pass a
configured `OllamaClient` only if you want the Settings model picker to drive it. If `Preferences`
has no model field yet, `OllamaCleanupService()` is sufficient and requires no other change — the
existing `DictationCoordinator` already builds a `CleanupContext` and calls
`cleanup.cleanup(raw, context:)`.

## Optional: wire adaptive style memory (brief §5A) — recommended, still one file (AppState) + coordinator

The `styleSamples` field is currently passed as `[]` in `DictationCoordinator`. To enable tone
anchoring, `AppState` should own one `StyleSampleStore` and hand it to the coordinator so it can:

1. On building `CleanupContext`, set `styleSamples: styleSampleStore.recent(3, for: snap.context)`.
2. After a successful cleaned insertion, call `styleSampleStore.append(finalText, for: snap.context)`.

`StyleSampleStore` is plain (not `@MainActor`, not `ObservableObject`) and safe to call from the
coordinator's async path. If M-pipeline owns `DictationCoordinator`, this is a 2-line change there
plus one added init parameter; keep the default `[]` behavior if you defer it. No contract signature
changes are required — `CleanupContext.styleSamples` already exists.

## Guarantees

- No network except `http://127.0.0.1:11434`. No telemetry.
- Cleanup never throws, never hangs (4s cap), always falls back to raw text with `wasCleaned == false`.
