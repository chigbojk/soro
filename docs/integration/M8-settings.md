# M8-Settings Integration Note

## File produced

`Soro/Soro/UI/Dashboard/SettingsView.swift`

## How SettingsView is already wired

`DashboardWindow.swift` already instantiates `SettingsView()` in its `detail` switch case:

```swift
case .settings: SettingsView()
```

The view uses `@EnvironmentObject private var prefsStore: PreferencesStore` to read/write
settings. `PreferencesStore` must be injected into the environment by the parent before
`SettingsView` appears.

## AppState injection required

In `AppState`, expose the three service closures that `SettingsView` accepts as init
parameters so the real implementations are wired in. There are two patterns:

### Option A — pass closures when constructing SettingsView (preferred, no contract change)

In `DashboardWindow.swift` (or wherever the view is instantiated) change:

```swift
case .settings: SettingsView()
```

to:

```swift
case .settings: SettingsView(
    transcriptionIsModelReady: { [weak appState] name in
        appState?.transcription.isModelReady ?? false
    },
    transcriptionPrepareModel: { [weak appState] name, progress in
        try await appState?.transcription.prepareModel(name, progress: progress)
    },
    cleanupIsAvailable: { [weak appState] in
        await appState?.cleanup.isAvailable() ?? false
    }
)
```

`appState` is the `AppState` instance already held by `SoroApp`.

### Option B — inject via EnvironmentObject (alternative)

Add `@EnvironmentObject var appState: AppState` to the view hierarchy in `SoroApp`
alongside the existing store injections, then access `appState.transcription` and
`appState.cleanup` directly inside the view. This requires no change to `SettingsView.swift`
— only the environment injection site changes.

## EnvironmentObject the view reads

`SettingsView` reads exactly **one** store via `@EnvironmentObject`:

| EnvironmentObject type | Injected where |
|---|---|
| `PreferencesStore` | Already injected by `SoroApp` into the dashboard window environment |

No additional store injections are needed for `SettingsView`.

## SMAppService (launch at login)

`GeneralSection` calls `SMAppService.mainApp.register()` / `.unregister()`. This requires
`ServiceManagement.framework` — no entitlement changes are needed since sandbox is OFF.
The app must be running from its final install location (not `/tmp`) for SMAppService to
work correctly.

## Microphone list

`MicrophoneSection` calls `AVCaptureDevice.DiscoverySession` to enumerate mics. This does
not require an authorization prompt on its own; authorization is handled elsewhere (onboarding).
The picker falls back gracefully to "System Default" if no named devices are available.

## Key-capture recorder

`HotkeyRecorderField` installs a **local** `NSEvent` monitor (not a global tap). It captures
the next keypress and converts it to `HotkeyData` using the private `HotkeyData.from(event:)`
extension defined in `SettingsView.swift`. This extension is `private` and does not affect
any other module.

After capture the new binding is written to `prefsStore.prefs.hotkeyData` (and
`selectedHotkey`), then `prefsStore.save()` is called. For the change to take effect in the
running `HotkeyManager` the coordinator/AppState must observe `prefs.$hotkeyData` and call
`hotkeyManager.updateBindings(from:)`:

```swift
// In AppState.init or a Combine sink:
preferencesStore.$prefs
    .map(\.hotkeyData)
    .removeDuplicates()
    .sink { [weak self] _ in
        guard let self else { return }
        hotkeyManager.updateBindings(from: preferencesStore.prefs)
    }
    .store(in: &cancellables)
```
