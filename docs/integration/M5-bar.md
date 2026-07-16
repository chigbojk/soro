# M5 — Recording bar (UI/Bar/) integration

Scope files (all under `Soro/Soro/UI/Bar/`):
- `RecordingBarModel.swift` — pure, AppKit-free presentation logic (phase mapping,
  frame string codec, placement/clamp, timer + waveform helpers). Unit-tested.
- `WaveformView.swift` — N-bar SwiftUI waveform driven by a rolling `[CGFloat]` window.
- `RecordingBarView.swift` — the capsule content (recording/transcribing/done/dormant).
- `RecordingBarPanel.swift` — the borderless non-activating `NSPanel` wrapper.
- Tests: `Soro/SoroTests/RecordingBarModelTests.swift`.

No contract signatures changed. `RecordingBarView(coordinator:)` and
`RecordingBarPanel(coordinator:)` still compile exactly as the M1 stubs did
(all new parameters have defaults), so nothing that already calls them breaks.

## What AppState should replace / wire

M1 has no `RecordingBarPanel` instance in `AppState`. Add one and install it.

### 1. Construct the panel (in `AppState.init`, after `coordinator` is built)

`RecordingBarPanel` deliberately does NOT import `PreferencesStore`. Feed it
closures. The frame is persisted as a single string; the simplest bridge stores
it in `PreferencesStore` (add a `barFrameString: String?` pref, OR reuse the
existing `barFrameX`/`barFrameY` by encoding/decoding through the closure — see
note below).

```swift
let barPanel = RecordingBarPanel(
    coordinator: coordinator,
    levelStream: audio.levelStream,                       // AudioCaptureService.levelStream
    getFrame: { [weak prefs] in prefs?.prefs.barFrameString },
    setFrame: { [weak prefs] s in
        prefs?.prefs.barFrameString = s
        prefs?.save()
    },
    onFirstMove: { [weak stats] in stats?.markBarMoved() },   // sets barEverMoved
    notchEnabled:    { [weak prefs] in prefs?.prefs.enableNotchView ?? true },
    hideBar:         { [weak prefs] in prefs?.prefs.hideBar ?? false },
    hideBarWhenIdle: { [weak prefs] in prefs?.prefs.hideBarWhenIdle ?? true })
self.recordingBarPanel = barPanel   // store as a let/var property on AppState
```

Note on frame storage: `Preferences` currently exposes `barFrameX`/`barFrameY`
(Doubles). The panel persists a full "x,y,w,h" string. Cheapest option: add
`var barFrameString: String?` to `Preferences` (with a `nil` default) and use it
above. If you prefer to keep only X/Y, have `setFrame` parse the string with
`RecordingBarModel.decodeFrame` and store the origin, and `getFrame` rebuild a
string from the stored origin plus the default size via
`RecordingBarModel.encodeFrame` — the codec is public for exactly this.

### 2. Install it once the app is up (in `AppState.startServices()`)

```swift
recordingBarPanel.install()   // builds the panel and syncs visibility to state
```

`install()` is idempotent and safe to call on the main actor. The panel then
observes `coordinator.$state` itself and orders in/out with
`orderFrontRegardless()` (never activates the app, never steals focus). No
further calls are needed on state changes.

### Behavior summary
- Visibility is derived by `RecordingBarModel.phase(...)`: `enableNotchView` off
  or `hideBar` on ⇒ always hidden; idle ⇒ hidden (`hideBarWhenIdle == true`) or a
  dormant click pill (`false`); recording ⇒ waveform + timer + lock glyph (locked)
  + X cancel; transcribing/inserting ⇒ shimmer; done ⇒ brief flash then hide.
- The X button calls `coordinator.cancelRecording()`.
- Dragging the background persists the frame via `setFrame` and fires
  `onFirstMove` once (wire to `StatsStore.markBarMoved`).
- Default position is centered under the notch on the main screen; a persisted
  frame is clamped on-screen before use.

### Do NOT
- Do not add a second observer of `coordinator.state` for visibility — the panel
  owns that.
- The panel level is `statusBar + 1` with `[.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary]`; keep it above the notch and over full-screen apps.
