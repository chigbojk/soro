# M4 — Hotkey engine integration

Owner: M4-hotkey. Files delivered:
- `Soro/Soro/Core/Hotkey/HotkeyGestureRecognizer.swift` (new — pure state machine)
- `Soro/Soro/Core/Hotkey/HotkeyManager.swift` (filled M1 skeleton — real `CGEventTap`)
- `Soro/SoroTests/HotkeyGestureRecognizerTests.swift` (25 tests)

`HotkeyGesture` (Core/Hotkey/HotkeyGesture.swift) and `HotkeyManagerDelegate` are unchanged from the
contract. `HotkeyManager`'s public surface matches CONTRACTS.md exactly (`delegate`,
`isRecordingActive`, `start() throws`, `stop()`, `updateBindings(from:)`).

## What AppState must do

`HotkeyManager` is now concrete and functional — there is **no stub to replace**; the M1 skeleton is
filled in place. AppState wires it as already implied by the contract:

```swift
// AppState composes services and wires HotkeyManager -> DictationCoordinator.
let hotkeyManager = HotkeyManager()              // no init params
hotkeyManager.delegate = self                    // or a small adapter forwarding to the coordinator
hotkeyManager.updateBindings(from: preferencesStore.prefs)   // call on launch AND whenever prefs change

do {
    try hotkeyManager.start()                    // creates the CGEventTap
} catch let e as HotkeyManagerError {
    // e == .accessibilityNotTrusted -> route user to onboarding / System Settings.
    // Do NOT crash; degrade to "hotkey inactive" and surface the prompt (M9 onboarding).
}
```

### Delegate → coordinator mapping (business logic lives in the coordinator, not here)

`func hotkeyManager(_ m: HotkeyManager, didEmit gesture: HotkeyGesture)` should dispatch:

| gesture               | coordinator call                         |
|-----------------------|------------------------------------------|
| `.pushToTalkBegan`    | `coordinator.beginRecording(locked: false)` |
| `.pushToTalkEnded`    | `coordinator.endRecording()`             |
| `.lockToggledOn`      | *recording already began on the prior* `.pushToTalkBegan`; just mark the state locked. The recognizer keeps the live session — do **not** start a new recording. Call `coordinator.beginRecording(locked: true)` **only if** your coordinator is idempotent about an already-running session; otherwise add a `coordinator.markLocked()` / set `state = .recording(locked: true)`. |
| `.lockToggledOff`     | `coordinator.endRecording()`             |
| `.cancel`             | `coordinator.cancelRecording()`          |
| `.pasteLastTranscript`| `coordinator.pasteLast()`                |

Important nuance: the recognizer emits `.pushToTalkBegan` on the **first** trigger down, then—if a
fast second tap follows—`.lockToggledOn`. So a locked session is `began` **then** `lockOn`, with a
single live recording throughout (no stop/restart, no dropped audio). Handle `.lockToggledOn` as an
in-place upgrade of the already-running recording, not a fresh start.

### Keep `isRecordingActive` in sync

Set `hotkeyManager.isRecordingActive` from the coordinator's state so external callers see it. The
recognizer also tracks recording state internally (authoritative for Esc/lock), so this mirror is for
the coordinator's own view; it is not required for the state machine to function.

### Re-bind on preference changes

Call `hotkeyManager.updateBindings(from:)` whenever `PreferencesStore.prefs` changes (trigger key,
paste combo). No need to stop/start the tap.

## Runtime requirements

- **Accessibility permission** is mandatory. `start()` throws `.accessibilityNotTrusted` when
  `AXIsProcessTrusted()` is false. Unsigned dev builds re-prompt on every rebuild (Appendix C).
- The tap runs on the **main run loop**; recognizer callbacks are already hopped to main via
  `DispatchQueue.main.async`, so delegate/coordinator work is main-actor safe.
- The tap is **listen-only** — it never swallows the user's keystrokes.

## Timing model (documented in code, summarized)

- Trigger is modifier-only (default Left Option, keyCode 58).
- First down → `pushToTalkBegan` immediately (prompt PTT).
- Held → nothing until release → `pushToTalkEnded`. A slow hold can never become a lock.
- Quick release → pending window (`doubleTapWindow` default 0.28s, from release). A second down inside
  the window → `lockToggledOn`; window expiry with no second tap → `pushToTalkEnded` (a real short PTT,
  never a swallowed input).
- Locked: any trigger down → `lockToggledOff` + `pushToTalkEnded`.
- Esc while recording (ptt/pending/locked) → `cancel`, discard.
- Paste combo: Left Cmd + configured key → `pasteLastTranscript`.

The double-tap window has no dedicated field in `Preferences` yet; it defaults to 0.28s inside
`HotkeyRecognizerConfig`. If a settings slider is added later, plumb it through
`HotkeyRecognizerConfig.doubleTapWindow` in `updateBindings`.
