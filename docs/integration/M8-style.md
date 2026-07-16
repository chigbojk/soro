# M8-style integration notes

## What was built

`Soro/Soro/UI/Dashboard/StyleMatchingView.swift` — the full Style Matching
dashboard screen as specified in brief §4b / §5.

## Files created / modified

| File | Change |
|---|---|
| `Soro/Soro/UI/Dashboard/StyleMatchingView.swift` | Full implementation (replaces M1 placeholder). |
| `Soro/SoroTests/StyleMatchingViewTests.swift` | 9 unit tests; all pass. |

## EnvironmentObject requirement

`StyleMatchingView` requires exactly one environment object:

```swift
StyleMatchingView()
    .environmentObject(appState.personalizationStore)   // PersonalizationStore
```

`DashboardWindow.swift` already switches to `StyleMatchingView()` in its detail
`ViewBuilder`. The only wiring needed is ensuring `personalizationStore` is injected
into the environment at the window's root. In `AppState`, `personalizationStore` is
already constructed and available; the integration point is in
`App/SoroApp.swift` (or wherever the `DashboardWindow` is opened), e.g.:

```swift
DashboardWindow()
    .environmentObject(appState.personalizationStore)
    // ... plus other stores used by HomeView, DictionaryView, SettingsView
```

If AppState already injects all stores at the top-level `WindowGroup` / `Window`
scene, no change is needed beyond verifying `personalizationStore` is in that set.

## No changes to DashboardWindow.swift

The existing `DashboardWindow.detail` already instantiates `StyleMatchingView()`.
Do NOT edit `DashboardWindow.swift`.

## PersonalizationStore is the sole dependency

`StyleMatchingView` reads and writes **only** through `PersonalizationStore.prefs`
(a `@Published` `PersonalizationPreferences`). It calls `store.save()` on every
picker change or text field edit — saves are synchronous JSON writes to
`Preferences/personalization_preferences.json`, consistent with every other store.

## Binding pattern used

Each context card creates bindings inline:

```swift
Binding(
    get: { store.prefs.workMessagingStyle },
    set: { store.prefs.workMessagingStyle = $0; store.save() })
```

This means every UI interaction auto-persists without a separate Save button.

## Stub replacement

No stub replacement is required for this milestone. `PersonalizationStore` was
already a full implementation from M1. `StyleMatchingView` was the only stub
(a `PlaceholderDetail`); it is now fully implemented.

## Style values accepted

| Field | Accepted values |
|---|---|
| Messaging style | `"formal"` / `"casual"` |
| Scribe writing style | `"natural"` / `"polished"` / `"concise"` |
| Personal tweak | Any non-nil String (empty string = no tweak) |

These values are passed verbatim by `PersonalizationStore.styleFor(_:)` into
`CleanupContext.messagingStyle`, `.scribeStyle`, and `.personalTweak`, which
`PromptBuilder` interpolates into the Ollama system prompt (Appendix B placeholders
`[MESSAGING_STYLE]`, `[SCRIBE_STYLE]`, `[PERSONAL_TWEAK]`).
