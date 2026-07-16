# Integration: notch-bar (recording bar redesign)

Scope touched: `UI/Bar/` only. Redesigns the recording bar into a wide Willow/Wispr-style
notch pill: centered under the physical notch, app icon on the left, live waveform on the right.

## What changed (all inside UI/Bar/)

- `RecordingBarModel.swift` — added pure geometry + icon logic (unit-tested):
  - `pillWidth` (340) / `pillHeight` (40) constants — the wide capsule that flanks the notch.
  - `notchCenterX(fullFrame:auxLeftMaxX:safeAreaLeftInset:)` — computes the notch's horizontal
    center in AppKit screen coords. Mirrors the aux-area left edge across the display center;
    falls back to `fullFrame.midX` when there is no notch.
  - `defaultOrigin(in:size:topInset:centerX:)` — now takes an optional `centerX` (the notch
    center); nil keeps the old `screenFrame.midX` behavior.
  - `LeftIcon` enum + `leftIcon(hasCapturedIcon:)` — chooses app-icon vs `mic.fill` fallback.
- `LeftIconProvider.swift` (new) — `@MainActor ObservableObject` that snapshots
  `NSWorkspace.shared.frontmostApplication?.icon` at record start. Resolver is injectable for
  tests. `captureFrontmost()` / `clear()` / `icon` / `hasIcon`.
- `LeftIconView.swift` (new) — renders the captured icon (~19pt, rounded) or the mic fallback.
- `RecordingBarView.swift` — new `leftIcon: LeftIconProvider` observed object (defaulted, so the
  bare `RecordingBarView(coordinator:)` initializer still compiles). Recording chrome is now
  `[app icon][lock?][waveform expands][timer][X]`; pill widens to `pillWidth` while recording.
  Waveform bar count bumped to 30 and expands with `maxWidth: .infinity`.
- `RecordingBarPanel.swift` — owns a private `LeftIconProvider`, passes it into the view,
  captures the frontmost icon on the idle→recording edge and clears it on return to idle.
  `positionUnderNotch()` now computes the notch center via `NSScreen.auxiliaryTopLeftArea` +
  `safeAreaInsets.left` and passes it to `defaultOrigin`. Default panel size is now the wide pill.

## AppState / other modules: NO wiring changes required

The `RecordingBarPanel(...)` initializer signature is **unchanged** — the same closures
(`getFrame`, `setFrame`, `onFirstMove`, `notchEnabled`, `hideBar`, `hideBarWhenIdle`) are still
used exactly as in `AppState.swift`. The `LeftIconProvider` is created and driven entirely inside
the panel; nobody outside `UI/Bar/` needs to construct or feed it.

Notes for reviewers:
- The frame-persistence / `visibleFrame` clamp fix is preserved: persisted frames still clamp to
  `screen.visibleFrame`; only the *default* (unmoved) origin now honors the notch center.
- The icon is captured at **record start** (not at insertion), matching the "frontmost app at
  record start determines context" rule (App C). If focus changes mid-recording the pill keeps
  showing the app you started dictating into.
- Fully graceful: no frontmost app / no icon → `mic.fill`. No notch → centered on `midX`.

## Verification

- `xcodegen generate && xcodebuild -project Soro.xcodeproj -scheme Soro -destination
  'platform=macOS' build` → BUILD SUCCEEDED.
- `RecordingBarModelTests` (all, incl. new notch-geometry + left-icon + provider tests) pass.
