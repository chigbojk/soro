# Integration: stats-recap ("Wrapped"-style stats + monthly recap)

Task key: **stats-recap**

## What this adds

- **Richer aggregation in `StatsStore` / `UsageStats`**: per-app paste counts
  (`appUsage: [bundleId: AppUsageStat]`), per-month rollups (`monthly: [yyyy-MM: MonthlyStat]`),
  a most-transcribed-words tally (`wordCounts: [word: Int]`), and a `longestStreak` high-water
  mark. All persisted in `feature_usage_stats.json`, fully back-compatible (every new key is
  optional/defaulted; a legacy file with only the original four keys decodes unchanged).
- **`RecapSummary` + `StatsStore.computeRecap(month:topN:now:)`** — a presentation-ready recap
  (words, dictations, time saved, top apps, top words, current + longest streak).
- **`RecapCard`** on `HomeView` — a dismissible "This month" highlight placed below the stat
  cards, with app icons resolved via `NSWorkspace` by bundle id, a top-words chip cloud (reuses
  the shared `FlowLayout`), and streak chips. Dismissal is persisted per-month via
  `@AppStorage("home.recapDismissedMonth")`, so it stays hidden until the next month rolls over.
- **`RecapNotifier`** (`Core/RecapNotifier.swift`) — posts a once-per-calendar-month local
  `UNUserNotification` summarizing the *previous* completed month. Guarded by
  `UsageStats.lastRecapMonthKey`. Requests authorization lazily and no-ops gracefully if
  notifications are unavailable/denied or the app is unbundled.

## Wiring the orchestrator must do (both one-liners, outside this scope)

### 1. Coordinator — record per-app + text

In `Core/Pipeline/DictationCoordinator.swift`, `runPipeline()`, replace the existing stats call
(currently at the `if finalText != Transcript.errorSentinel {` block, ~line 245):

```swift
stats.recordDictation(words: wordCount(finalText), duration: captured.duration)
```

with the richer overload (passes the target app + final text so the recap can attribute apps and
mine words):

```swift
stats.recordDictation(words: wordCount(finalText),
                      duration: captured.duration,
                      appName: snap.appName,
                      bundleId: snap.bundleId,
                      text: finalText)
```

`snap` is the `ContextDetector` snapshot already in scope (`let snap = contextSnapshot ?? ...`).
The old zero-arg-app signature still exists, so nothing breaks if this line is left as-is — the
recap simply won't have per-app/word data.

### 2. AppState — run the monthly recap check at launch

In `App/AppState.swift`, right after the existing stats recompute (~line 162,
`stats.recompute(from: transcripts.recent(limit: 10_000))`), add:

```swift
RecapNotifier(stats: stats).checkAndNotify()
```

`checkAndNotify()` self-guards via `lastRecapMonthKey` (fires at most once per calendar month),
targets the previous completed month, and no-ops if notifications aren't available. Safe to call
on every launch. `RecapNotifier` is `@MainActor`, matching `AppState`'s init context.

## Files touched (scope)

- `Soro/Soro/Models/UsageStats.swift` — extended (new fields, `AppUsageStat`,
  `MonthlyStat`, `RecapSummary`, `monthKey` helper).
- `Soro/Soro/Stores/StatsStore.swift` — new `recordDictation` overload, `computeRecap`,
  longest-streak tracking, local tokenizer/stopwords, pure helpers.
- `Soro/Soro/Core/RecapNotifier.swift` — new.
- `Soro/Soro/UI/Dashboard/Home/RecapCard.swift` — new.
- `Soro/Soro/UI/Dashboard/HomeView.swift` — added `recapSection` below the stat cards.
- `Soro/SoroTests/StatsRecapTests.swift` — new (14 tests).

## Verification

- `xcodegen generate && xcodebuild -project Soro.xcodeproj -scheme Soro
  -destination 'platform=macOS' build` → **BUILD SUCCEEDED**.
- `StatsRecapTests` (14), plus existing `HomeViewTests` (17) and `StoreTests` (8) → all pass.
- No live notification tests (`RecapNotifier` is injected with a `nil` center in tests, so no
  real notification is posted).
