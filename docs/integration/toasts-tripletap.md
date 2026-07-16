# Integration: Toasts + Triple-Tap (task `toasts-tripletap`)

Adds a transient TOAST system (top-right, countdown-drained, non-focus-stealing) and a
TRIPLE-TAP Left-Option gesture that shows the current microphone. All wiring below is already
done inside this scope (`AppState`, `DictationCoordinator`, hotkey files). This doc is for other
modules that touch the same seams.

## New / changed types

- `HotkeyGesture.showMicrophone` — new enum case (`Core/Hotkey/HotkeyGesture.swift`).
  **Any exhaustive `switch` over `HotkeyGesture` must add this case.** Two test helpers already
  updated (`HotkeyGestureRecognizerTests`, `HotkeyAdversarialTests` → `case .showMicrophone`).
- `Toast` (struct) + `ToastCenter` (`@MainActor ObservableObject`) — `UI/Toast/ToastCenter.swift`.
- `ToastView` / `ToastStackView` — `UI/Toast/ToastView.swift`.
- `ToastPanel` — `UI/Toast/ToastPanel.swift`, a non-activating top-right `NSPanel`.

## ToastCenter API (the decoupled seam)

```swift
@MainActor final class ToastCenter: ObservableObject {
    @Published private(set) var toasts: [Toast]
    nonisolated init(maxVisible: Int = 4, now: @escaping () -> TimeInterval = …)  // injectable clock
    @discardableResult func show(_ toast: Toast) -> UUID
    @discardableResult func show(_ message: String, systemImage: String,
                                 style: Toast.Style = .info, duration: TimeInterval? = 3.0) -> UUID
    func dismiss(_ id: UUID)                      // clear a specific toast
    @discardableResult func replace(_ id: UUID, with: Toast) -> UUID   // in-place, keeps slot
    func dismissAll()
    @discardableResult func expire(at: TimeInterval) -> Bool   // pure; used by tests + timer
    func nextExpiry() -> TimeInterval?
    // semantic helpers: showTranscribing() (sticky), showPasted(), showTranscribeFailed(),
    // showMicrophone(_ name:)
}
```

- `duration == nil` → **sticky** toast (no countdown, never auto-expires). "Transcribing…" uses this.
- The pure `expire(at:)` / `remainingFraction(at:)` / `hasExpired(at:)` logic is unit-tested with
  an injected clock (`ToastCenterTests`). The internal `Timer` is thin plumbing over that core.
- `init` is `nonisolated` so it can be a default-argument value in other `@MainActor` initializers.

## Coordinator wiring (already done)

`DictationCoordinator.init` gained `toasts: ToastCenter = ToastCenter()` (default no-op center — the
pipeline works headless / in tests without a panel). Emissions:

- `endRecording()` → `toasts.showTranscribing()` (sticky), id stored.
- End of `runPipeline()` → `resolveTranscribingToast(succeeded:finalText:)` replaces the sticky toast
  in place with **"Pasted"** (`.success`, 1.6 s) or **"Failed to transcribe"** (`.failure`, 3.0 s).
  Failure = insertion failed OR error sentinel OR empty text.
- `cancelRecording()` → dismisses any in-flight transcribing toast.

If you construct a `DictationCoordinator` yourself and want visible toasts, **pass the shared
`ToastCenter`** (the one also handed to `ToastPanel`). Otherwise the default detached center's
toasts go nowhere (harmless).

## AppState wiring (already done)

- Owns `let toastCenter: ToastCenter` and `let toastPanel: ToastPanel`.
- One shared `toastCenter` is injected into `DictationCoordinator` **and** `ToastPanel(center:)`.
- `startServices()` calls `toastPanel.install()` (idempotent) alongside `recordingBarPanel.install()`.
- `dispatch(.showMicrophone)` → `toastCenter.showMicrophone(currentMicrophoneName())`.
- `currentMicrophoneName()` resolves `PreferencesStore.prefs.selectedMicrophoneUID` via
  `AVCaptureDevice.DiscoverySession` → device `localizedName`; falls back to the system default
  input, then `"Default microphone"`.

## Triple-tap semantics (recognizer)

`HotkeyGestureRecognizer` gained a `lockedPendingTriple(lockReleaseTime:)` state:

- Double-tap-lock unchanged: `began` → `lockOn` on the same live session.
- After the lock tap is **released**, the recognizer enters `lockedPendingTriple` (recording stays
  live). A **third down within `doubleTapWindow`** emits `.showMicrophone` and returns to `.locked`
  (recording untouched). If the window elapses (via `tick`/next event) it settles back to `.locked`
  with **no** gesture, so a later tap still **stops** normally.
- Esc during `lockedPendingTriple` cancels (recording was active).
- `HotkeyManager` now reschedules its pending-expiry timer after every handled event (a trigger-up
  can enter a timed window without emitting a gesture). Lazy expiry-on-next-event still backs this up.

**Behavior change of note:** three *rapid* taps used to = lock-then-stop; they now = lock-then-show-mic
(the recording stays locked). A deliberate (post-window) tap still stops. The affected adversarial
test was updated to the new contract and a companion "slow tap still stops" test added.

## Non-focus-stealing guarantees

`ToastPanel` is `[.borderless, .nonactivatingPanel]`, `canBecomeKey/Main = false`,
`ignoresMouseEvents = true`, `orderFrontRegardless()` (never activates the app), floats above
full-screen apps, anchored to `NSScreen.main.visibleFrame` top-right (clears the menu bar / notch).

## Files touched

- `Soro/Soro/Core/Hotkey/HotkeyGesture.swift`
- `Soro/Soro/Core/Hotkey/HotkeyGestureRecognizer.swift`
- `Soro/Soro/Core/Hotkey/HotkeyManager.swift`
- `Soro/Soro/Core/Pipeline/DictationCoordinator.swift`
- `Soro/Soro/App/AppState.swift`
- `Soro/Soro/UI/Toast/ToastCenter.swift` (new)
- `Soro/Soro/UI/Toast/ToastView.swift` (new)
- `Soro/Soro/UI/Toast/ToastPanel.swift` (new)
- Tests: `SoroTests/ToastCenterTests.swift` (new), `HotkeyGestureRecognizerTests.swift`,
  `HotkeyAdversarialTests.swift`
