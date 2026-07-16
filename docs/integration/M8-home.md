# M8-home Integration Notes

## Scope

`Soro/Soro/UI/Dashboard/HomeView.swift` (full replacement of the M1 placeholder)
`Soro/Soro/UI/Dashboard/Home/StatCardView.swift` (new subview)
`Soro/Soro/UI/Dashboard/Home/HistoryRowView.swift` (new subview)
`Soro/SoroTests/HomeViewTests.swift` (unit tests)

## What AppState must provide

`HomeView` is a pure SwiftUI view; it reads exclusively from `@EnvironmentObject` stores.
No changes to `AppState.swift` are required for compilation. The following stores must be
injected into the SwiftUI environment for `HomeView` to display real data:

```swift
// Inside AppState or wherever DashboardWindow is opened:
DashboardWindow()
    .environmentObject(transcriptStore)   // TranscriptStore
    .environmentObject(statsStore)        // StatsStore
    .environmentObject(preferencesStore)  // PreferencesStore
```

`DashboardWindow` already switches to `HomeView()` in its detail switcher — no edit needed
there. The `HomeView` placeholder from M1 is fully replaced; the type name is unchanged.

## Optional wiring for action closures

`HomeView` exposes two closure properties for actions that depend on later milestones:

```swift
HomeView(
    onReinsert: { transcript in coordinator.reinsert(transcript) },  // M3 / InsertionService
    onPlayAudio: { transcript in audioPlayer.play(transcript.audioURL) } // future audio player
)
```

Both default to `{ _ in }` (no-op) so the view compiles and runs without those milestones.
The "Re-insert" context-menu item is always visible but functionally inert until M3 wires
`onReinsert`. The "Play Audio" item is always visible but `.disabled` when `transcript.audioURL == nil`.

## Stats recomputation

`StatsStore.recompute(from:)` is called by `AppState` at launch (M1 skeleton).
`HomeView` binds directly to `StatsStore`'s `@Published` properties:
- `dictatedWords` — total words across all transcripts
- `timeSavedSeconds` — derived heuristic (typing at 40 wpm vs actual recording duration)
- `dayStreak` — consecutive calendar-day usage
- `avgWPM` — average speaking speed

No additional wiring is required; these update automatically via `@EnvironmentObject`.

## History paging

`HomeView` calls `transcriptStore.recent(limit: 40, offset: N)` as the user scrolls.
Search calls `transcriptStore.search(q, limit: 200)`. Both methods already exist in
`TranscriptStore` per the CONTRACTS.md signature.

When `TranscriptStore` is mutated (e.g. a new dictation is added by `DictationCoordinator`),
`HomeView` does not auto-refresh the list — it relies on `onAppear` + the search/scroll cycle.
A future improvement: `TranscriptStore` could expose an `@Published var changeToken: Int` that
`HomeView` observes to trigger a reload, but this is not required for v1.
