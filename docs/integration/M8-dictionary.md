# M8-dictionary Integration Notes

## Files delivered

- `Soro/Soro/UI/Dashboard/DictionaryView.swift` — full implementation
- `Soro/SoroTests/DictionaryViewTests.swift` — 11 unit tests (all green)

## AppState wiring required

`DictionaryView` is already referenced in `DashboardWindow.swift` (the `case .dictionary:` branch). No change to `DashboardWindow.swift` is needed.

The view resolves its stores via `@EnvironmentObject`. `AppState` already constructs `GlossaryStore` and `AutoDictionaryStore` and the following `.environmentObject()` injections must be present in the app entry point (or wherever `DashboardWindow` is opened):

```swift
DashboardWindow()
    .environmentObject(appState.glossaryStore)       // GlossaryStore
    .environmentObject(appState.autoDictionaryStore) // AutoDictionaryStore
    // (other stores for other views…)
```

`AppState` already has:
```swift
let glossaryStore: GlossaryStore
let autoDictionaryStore: AutoDictionaryStore
```
No new properties needed on `AppState`.

## No stub replacement required

`DictionaryView` binds directly to `GlossaryStore` and `AutoDictionaryStore` (concrete `ObservableObject` classes already implemented in M1). There are no service stubs to swap.

## Public types exported from DictionaryView.swift

- `struct DictionaryView: View` — main entry point, matches `DashboardWindow.swift` usage
- `enum DictionaryTab` — `.terms` / `.shortcuts`; internal to this file but accessible for tests
- `struct AddTermSheet: View` — standalone sheet, usable for deep-link if needed
- `enum AddTermResult` — `.add(GlossaryEntry)` / `.update(GlossaryEntry)`
- `struct FlowLayout: Layout` — wrapping chip layout; available to other UI files in the same module

## Behavior summary

- "Personal Terms" tab: `GlossaryEntry` where `isReplacement == false`
- "Personal Shortcuts" tab: `GlossaryEntry` where `isReplacement == true`
- Search filters by `term` and (for shortcuts) `replacement` text
- Chip hover reveals enable/disable (eye), edit (pencil), delete (trash) controls
- Context menu on each chip for keyboard-only access
- Auto-Learned suggestions row appears in the Terms tab when `AutoDictionaryStore.suggestions()` is non-empty and the suggested word is not already in the glossary
- Suggestions can be added (creates a `GlossaryEntry` with `tag: "Auto-Learned"`) or dismissed via `AutoDictionaryStore.dismiss(_:)`
- Add/edit sheet: `isReplacement` picker toggles the "Expands to" field; sheet pre-selects the active tab's type
