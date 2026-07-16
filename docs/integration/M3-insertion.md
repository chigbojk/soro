# M3 — Insertion integration

## What changed
New file `Soro/Soro/Core/Insertion/PasteInsertionService.swift` implements the
`InsertionService` protocol for real. The `StubInsertionService` in `InsertionService.swift`
is left untouched (protocol + enum unchanged, per contract).

## Wiring in AppState.swift (the ONE change M3 needs)
In `AppState.init(...)`, replace the stub construction with the real service.

Current line (~50):
```swift
let insertion = StubInsertionService()
```
Replace with:
```swift
let insertion = PasteInsertionService(
    automaticEnter: { [weak preferencesStore] in
        preferencesStore?.prefs.cursorAutomaticEnter ?? false
    }
)
```
- `preferencesStore` is the `PreferencesStore` already constructed in `AppState.init`
  (use whatever local/property name it has at that point — it is created before services).
- All other init parameters have safe defaults:
  - `frontmostBundleID` → live `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`
  - `secureInputEnabled` → live `IsSecureEventInputEnabled()`
  - `pasteSettleMillis` → 150
  - `pasteboard` → `.general`
  - `postsEvents` → true (tests pass false to avoid synthesizing key events)

No other file changes are required. `self.insertion` assignment and the
`DictationCoordinator(... insertion: insertion ...)` wiring stay exactly as they are —
`PasteInsertionService` conforms to the same `InsertionService` type.

## Behavior notes for the coordinator (M-pipeline)
- `insert(_:)` returns `.pasted` | `.typed` | `.failedSecureInput` | `.failed`.
  On `.failedSecureInput` the pasteboard is never touched (password field active).
- `reinsertLast()` replays the last text handed to `insert` (post per-app-rules), re-checking
  secure input. Returns `.failed` if nothing was ever inserted or the prior insert short-circuited
  on secure input.
- The service is fully decoupled: it imports no stores. Config comes via the injected closures.
- Every path returns promptly; the only await is a ~150ms sleep between ⌘V and pasteboard restore.

## Requirements
- Accessibility permission is required for CGEvent posting to reach other apps (granted manually).
  Without it, ⌘V/typing silently no-op at the OS level but the service still restores the
  pasteboard and returns `.pasted`/`.typed` — it never hangs.
