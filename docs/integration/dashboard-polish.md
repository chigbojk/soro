# Integration: dashboard-polish

Task key: **dashboard-polish**
Scope: `UI/Dashboard/*` only. No store APIs, Core, or App/ touched. Auto-learn suggestion
logic and VAD slider logic are visually restyled only — their behavior is unchanged.

## What changed

A shared light theme was introduced and applied across every dashboard screen so the app
reads as a cohesive, Willow-grade product.

### New files
- `Soro/UI/Dashboard/Theme/SoroTheme.swift`
  - Redefines `enum SoroTheme` (the old 1-property placeholder in `DashboardWindow.swift`
    was removed; `SoroTheme.accent` still exists, now ~#5B4FE6).
  - Tokens: `accent`, `accentSoft`, `canvas` (cream), `card` (white), `accentTint`,
    `hairline`, `textPrimary/Secondary/Tertiary`, `Spacing`, `Radius`, `accentGradient`.
  - Reusable views/modifiers: `SoroCard` + `.soroCard(padding:cornerRadius:)`,
    `AccentIconTile`, `ScreenHeader`, `KeycapPill`.
- `Soro/UI/Dashboard/Home/FrontmostAppProvider.swift`
  - `@MainActor ObservableObject` that resolves the frontmost app name and up to 3
    running-app icons via `NSWorkspace` (2s poll while dashboard open; excludes our own
    app; fails gracefully to no icons / no name). Purely presentational.

### Modified files
- `DashboardWindow.swift` — removed the old `SoroTheme`; detail pane gets
  `SoroTheme.canvas` background. No routing/wiring changes; all `HomeView`/`SettingsView`
  closures untouched.
- `HomeView.swift`
  - New Willow header: `Hold [⌥ Opt] to dictate on [FrontmostApp]` using `KeycapPill` +
    accent-colored app name + an overlapping running-app icon cluster.
  - Replaced toolbar `.searchable` with an inline pill search field (still drives the same
    `searchText` → `reloadForSearch()` → `transcriptStore.search`/`recent` paging).
  - Stat cards now pass per-stat tints + a `unit` (wpm); history rows wrapped in a card with
    uppercase day-group headers and inset dividers.
  - Added `static func keycapLabel(for:)` (pure, unit-tested).
  - **Paging/search calls unchanged.**
- `Home/StatCardView.swift` — richer card: tinted symbol tile, large rounded value + unit +
  label hierarchy, shared card surface. Added optional `unit` and `tint` params (defaulted,
  so any other caller keeps working).
- `Home/HistoryRowView.swift` — muted time column, hover highlight + hover copy button, theme
  text tiers. Context-menu actions unchanged.
- `DictionaryView.swift` — `ScreenHeader`, canvas bg, shared `PillSearchField` (new shared
  view), chip grid + suggestions row on the shared card system. The
  `AutoLearnedSuggestionsRow` **suggestion logic is unchanged** — only the header icon/card
  chrome was restyled.
- `StyleMatchingView.swift` — `ScreenHeader`, canvas bg, `AccentIconTile` headers, cards via
  `.soroCard`. All `PersonalizationStore` bindings untouched.
- `SettingsView.swift` — `ScreenHeader`, canvas bg, `SettingsCard` now uses `AccentIconTile`
  + shared card surface (removed the empty `SettingsDivider` spacer). The
  `VoiceDetectionSection` slider + `VADPreview` **logic is unchanged** — restyled only.

### Tests
- `SoroTests/HomeViewTests.swift` — added `testKeycapLabelForModifiers` and
  `testKeycapLabelFallsBackToRawName` covering `HomeView.keycapLabel(for:)`.

## Wiring notes for the orchestrator
- No new environment objects or init parameters are required. `FrontmostAppProvider` is a
  `@StateObject` created inside `HomeView`; it starts on `.onAppear` and stops on
  `.onDisappear`. No entitlement changes — `NSWorkspace` running-app enumeration needs none.
- New source files are picked up by the recursive `Soro/Soro` glob in `project.yml`;
  run `xcodegen generate` before building (done). `Soro.xcodeproj` is not committed.

## Verification
- `xcodegen generate` — OK
- `xcodebuild -project Soro.xcodeproj -scheme Soro -destination 'platform=macOS' build`
  — **BUILD SUCCEEDED**
- Dashboard view tests (Home/Dictionary/StyleMatching/Settings): **54 passed, 0 failures**.
- No live mic/hotkey/UI tests run (headless); polish is visual and screenshotted by the
  orchestrator.
