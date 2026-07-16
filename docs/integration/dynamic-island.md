# Integration: Dynamic-Island recording bar (`dynamic-island`)

Scope: `Soro/UI/Bar/*` + `SoroTests/RecordingBarModelTests.swift`.

## What changed

The recording bar is now a TRUE macOS Dynamic Island that HUGS the notch instead
of a pill floating below it.

- **New file** `Soro/UI/Bar/NotchShape.swift` — pill outline with SQUARE top
  corners (flush to the screen's physical top so the black body merges with the
  physical notch) and ROUNDED bottom corners (`RecordingBarModel.bottomCornerRadius`
  = 18).
- `RecordingBarModel.swift`
  - Geometry: `fallbackNotchWidth` (200), `sideZoneWidth` (168), `pillHeight`
    (44), `bottomCornerRadius` (18).
  - `notchWidth(fullFrame:auxLeftMaxX:auxRightMinX:safeAreaTopInset:)` — exact
    notch gap from aux-area edges; mirrors when only the left edge is known;
    falls back to `fallbackNotchWidth` when only `safeAreaInsets.top > 0`; returns
    `0` (no gap → plain centered pill) on non-notched Macs.
  - `pillWidth(notchGap:sideZone:)` = `gap + 2*sideZone`. Legacy `pillWidth`
    static kept (uses the fallback notch) for previews/back-compat.
  - `topFlushOrigin(in:size:centerX:topInset:)` — TOP edge at `fullFrame.maxY`
    (pass the FULL `frame`, NOT `visibleFrame`), centered on the notch.
  - `shouldAdoptPersistedFrame(_:currentSize:userMoved:tolerance:)` — stale-frame
    guard: adopt a saved frame only when the user actually moved it AND the saved
    size matches the current pill (rejects the old 120×38 frame that stranded the
    bar).
  - `phase(for:)` now maps `.transcribing`/`.inserting`/`.done`/`.error` all to
    `.hidden`. Only `.dormant` and `.recording` are ever visible — the top-right
    TOAST owns Transcribing/Failed/Pasted status now. The `.transcribing` /
    `.doneFlash` enum cases remain but are unreachable via `phase(for:)`.
- `RecordingBarView.swift` — rebuilt to flank the notch: a LEFT zone (app icon +
  lock glyph) and a RIGHT zone (live `WaveformView` + elapsed timer + X cancel),
  separated by a transparent center gap == notch width. Backed by `NotchShape`
  filled near-solid black (opacity 0.94) with a subtle bottom shadow. New view
  params `notchGap` / `sideZone` (defaulted). Removed the transcribing/done
  chrome (now dead + unreachable).
- `RecordingBarPanel.swift`
  - Window level raised to `mainMenu + 1` so the island sits ABOVE the menu bar
    and merges with the notch band. Non-activating, joins all spaces, floats over
    full-screen, draggable, persists frame on move (unchanged).
  - Derives the notch gap at runtime via `NSScreen.auxiliaryTopLeftArea` /
    `auxiliaryTopRightArea` + `safeAreaInsets.top`, sizes the panel to
    `pillWidth(notchGap:)`, and pins it top-flush with `topFlushOrigin(in:
    screen.frame, ...)`.
  - `applyPersistedFrame()` now gates restoration through
    `shouldAdoptPersistedFrame(...)` using a new injected `barEverMoved: () -> Bool`
    closure; otherwise re-derives the top-flush position every appearance.

## REQUIRED wiring in `AppState.swift` (App/ scope — NOT modified here)

`RecordingBarPanel.init` gained one closure, `barEverMoved`. Without it the
persisted position is never restored (bar always re-pins top-flush — safe, but a
user's manual move won't survive relaunch). Add the read-back next to the
existing `onFirstMove`:

```swift
self.recordingBarPanel = RecordingBarPanel(
    coordinator: coordinator,
    levelStream: audio.levelStream,
    getFrame: { [weak prefs] in prefs?.prefs.barFrameString },
    setFrame: { [weak prefs] s in prefs?.prefs.barFrameString = s; prefs?.save() },
    onFirstMove: { [weak stats] in stats?.markBarMoved() },
    barEverMoved: { [weak stats] in stats?.stats.barEverMoved ?? false }, // ADD THIS
    notchEnabled: { [weak prefs] in prefs?.prefs.enableNotchView ?? true },
    hideBar: { [weak prefs] in prefs?.prefs.hideBar ?? false },
    hideBarWhenIdle: { [weak prefs] in prefs?.prefs.hideBarWhenIdle ?? true })
```

`UsageStats.barEverMoved` and `StatsStore.markBarMoved()` already exist.

## Verification

- `xcodegen generate && xcodebuild -project Soro.xcodeproj -scheme Soro
  -destination 'platform=macOS' build` → BUILD SUCCEEDED.
- `xcodebuild ... test -only-testing:SoroTests/RecordingBarModelTests` → 31
  tests pass. Covers: top-flush origin, notch-width (exact/mirror/fallback/zero),
  pill-width math, stale-frame rejection (size mismatch + never-moved), and the
  phase-visibility de-dupe (transcribing/done → hidden).
