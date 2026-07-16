import Foundation
import SwiftUI
import Combine
import AVFoundation

/// Composition root. Constructs the stores and (M1) stub service instances,
/// wires HotkeyManager → DictationCoordinator, and exposes everything the UI
/// binds to via `@EnvironmentObject`.
@MainActor
final class AppState: ObservableObject {
    // Stores
    let preferencesStore: PreferencesStore
    let transcriptStore: TranscriptStore
    let glossaryStore: GlossaryStore
    let personalizationStore: PersonalizationStore
    let statsStore: StatsStore
    let autoDictionaryStore: AutoDictionaryStore

    // Services (M1: stub implementations conforming to the protocols)
    let audio: AudioCaptureService
    let transcription: TranscriptionService
    let cleanup: CleanupService
    let insertion: InsertionService

    // Core
    let hotkeyManager: HotkeyManager
    let coordinator: DictationCoordinator

    // Recording bar (notch UI). Held so it stays installed for the app lifetime.
    let recordingBarPanel: RecordingBarPanel

    // Transient status toasts (top-right). Held for the app lifetime.
    let toastCenter: ToastCenter
    let toastPanel: ToastPanel

    /// True when the CGEventTap could not be created (Accessibility not granted).
    /// The UI (menu / onboarding) can surface this to prompt the user; the app
    /// keeps running with the hotkey inactive rather than crashing.
    @Published private(set) var hotkeyInactive: Bool = false

    /// True while the onboarding window should be shown (first launch).
    @Published var showOnboarding: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var accessibilityPollTimer: Timer?
    private let paths: AppPaths

    init(paths: AppPaths = .live) {
        self.paths = paths
        // Carry history/dictionary/preferences forward from the pre-rename
        // (Whispaa) data directory on first launch. Best-effort.
        if paths.root == AppPaths.live.root {
            DataMigration.migrateIfNeeded()
        }
        paths.ensureDirectories()

        // Stores
        let prefs = PreferencesStore(paths: paths)
        let transcripts = TranscriptStore(paths: paths)
        let glossary = GlossaryStore(paths: paths)
        let personalization = PersonalizationStore(paths: paths)
        let stats = StatsStore(paths: paths)
        let autoDict = AutoDictionaryStore(paths: paths)

        self.preferencesStore = prefs
        self.transcriptStore = transcripts
        self.glossaryStore = glossary
        self.personalizationStore = personalization
        self.statsStore = stats
        self.autoDictionaryStore = autoDict

        // Services (real implementations wired at integration).
        let audio = AVAudioEngineCaptureService(writer: RecordingWriter(paths: paths))
        let transcription = WhisperKitTranscriptionService(
            paths: paths,
            vadSensitivity: { [weak prefs] in prefs?.prefs.vadSensitivity ?? 0.5 }
        )
        let insertion = PasteInsertionService(
            automaticEnter: { [weak prefs] in
                prefs?.prefs.cursorAutomaticEnter ?? false
            })
        let cleanup = OllamaCleanupService(
            client: OllamaClient(model: prefs.prefs.ollamaModel),
            modelOverride: { [weak prefs] in prefs?.prefs.ollamaModel ?? "" })
        self.audio = audio
        self.transcription = transcription
        self.cleanup = cleanup
        self.insertion = insertion

        // Adaptive style memory (M7) — per-context ring buffer of accepted outputs.
        let styleSamples = StyleSampleStore(paths: paths)

        // Transient toasts — one shared center feeds both the coordinator (pipeline events)
        // and the top-right panel (§ toasts-tripletap).
        let toastCenter = ToastCenter()
        self.toastCenter = toastCenter

        // Core
        let hotkey = HotkeyManager()
        self.hotkeyManager = hotkey
        let coordinator = DictationCoordinator(
            audio: audio,
            transcription: transcription,
            cleanup: cleanup,
            insertion: insertion,
            glossary: glossary,
            transcripts: transcripts,
            stats: stats,
            autoDict: autoDict,
            personalization: personalization,
            preferences: prefs,
            styleSamples: styleSamples,
            recordingWriter: RecordingWriter(paths: paths),
            toasts: toastCenter)
        self.coordinator = coordinator

        // Toast panel (top-right). Installed in startServices so it observes the center.
        self.toastPanel = ToastPanel(center: toastCenter)

        // Recording bar panel (M5) — fed closures; imports no stores.
        self.recordingBarPanel = RecordingBarPanel(
            coordinator: coordinator,
            levelStream: audio.levelStream,
            getFrame: { [weak prefs] in prefs?.prefs.barFrameString },
            setFrame: { [weak prefs] s in
                prefs?.prefs.barFrameString = s
                prefs?.save()
            },
            onFirstMove: { [weak stats] in stats?.markBarMoved() },
            barEverMoved: { [weak stats] in stats?.stats.barEverMoved ?? false },
            notchEnabled: { [weak prefs] in prefs?.prefs.enableNotchView ?? true },
            hideBar: { [weak prefs] in prefs?.prefs.hideBar ?? false },
            hideBarWhenIdle: { [weak prefs] in prefs?.prefs.hideBarWhenIdle ?? true })

        // Auto-dictionary must not re-suggest terms already in the glossary (M6).
        autoDict.isInGlossary = { [weak glossary] lowercasedWord in
            guard let store = glossary else { return false }
            return store.enabledTerms().contains { $0.lowercased() == lowercasedWord }
        }

        // Wire hotkey → coordinator, load bindings.
        hotkey.delegate = self
        hotkey.updateBindings(from: prefs.prefs)

        // Re-bind the tap whenever the hotkey binding changes in Settings (M8-settings).
        prefs.$prefs
            .map(\.hotkeyData)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak hotkey, weak prefs] _ in
                guard let hotkey, let prefs else { return }
                hotkey.updateBindings(from: prefs.prefs)
            }
            .store(in: &cancellables)

        // Mirror recording state to the hotkey manager so external callers see it
        // (the recognizer tracks its own authoritative state; M4 note).
        coordinator.$state
            .map { state -> Bool in
                if case .recording = state { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak hotkey] active in hotkey?.isRecordingActive = active }
            .store(in: &cancellables)

        // Derive Home stats from existing transcripts (single pass).
        stats.recompute(from: transcripts.recent(limit: 10_000))
        // Post a once-per-month recap notification (self-guards; no-op if unavailable).
        RecapNotifier(stats: stats).checkAndNotify()

        // First-run onboarding: show if not yet completed (nil = new install → show).
        showOnboarding = !(prefs.prefs.hasCompletedOnboarding ?? false)

        // ALWAYS start OS integration on launch, deferred one runloop so the app
        // is fully up. Previously this only ran from the dashboard window's
        // onAppear or the onboarding flow — so a returning user who never opened
        // the dashboard got no hotkey tap and no Accessibility prompt. startServices
        // is idempotent, so the other call sites remain harmless.
        DispatchQueue.main.async { [weak self] in
            self?.startServices()
        }
    }

    // MARK: - Onboarding helpers (M9)

    /// Called by OnboardingView when the user completes or skips the flow.
    func dismissOnboarding() {
        showOnboarding = false
        preferencesStore.prefs.hasCompletedOnboarding = true
        preferencesStore.save()
    }

    /// Re-attempt starting the hotkey manager after Accessibility is granted.
    func retryHotkey() {
        guard hotkeyInactive else { return }
        do {
            try hotkeyManager.start()
            hotkeyInactive = false
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
        } catch {
            hotkeyInactive = true
        }
    }

    /// Polls Accessibility trust every 1.5s and starts the tap the moment it's
    /// granted, so the user never has to relaunch after flipping the toggle.
    private func beginAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if HotkeyManager.hasAccessibility {
                self.retryHotkey()
            }
        }
    }

    /// Starts OS integration (event tap + recording bar) and kicks off model
    /// preparation. Safe to call more than once (`install()` is idempotent).
    func startServices() {
        // Recording bar: build once, then it observes coordinator state itself.
        recordingBarPanel.install()

        // Toast panel: build once; it observes the toast center for show/hide.
        toastPanel.install()

        // Event tap — degrade gracefully if Accessibility isn't granted (no crash).
        do {
            try hotkeyManager.start()
            hotkeyInactive = false
        } catch {
            // .accessibilityNotTrusted / .tapCreationFailed → hotkey inactive.
            hotkeyInactive = true
            // Fire the OS Accessibility prompt so the user gets the system dialog
            // + "Open System Settings" button and Soro appears in the list, then
            // poll so the tap comes alive the instant they flip the toggle — no
            // relaunch needed (matches Willow's behavior).
            HotkeyManager.promptForAccessibility()
            beginAccessibilityPolling()
        }

        // Warm the default Whisper model in the background if it's already
        // installed — never block launch. First-time download is handled by
        // Settings/onboarding (M9).
        let transcription = self.transcription
        let paths = self.paths
        let model = ModelManager.selectedModel(from: preferencesStore.prefs)
        Task.detached(priority: .utility) {
            let manager = ModelManager(paths: paths)
            guard manager.isModelInstalled(model) else { return }
            try? await transcription.prepareModel(model) { _ in }
        }
    }
}

// MARK: - HotkeyManagerDelegate → coordinator gestures

extension AppState: HotkeyManagerDelegate {
    /// The manager always invokes this on the main thread (its recognizer callback hops to main
    /// before firing). We therefore dispatch *synchronously* on the MainActor rather than spawning
    /// a fresh `Task` per gesture: unstructured tasks carry NO ordering guarantee relative to one
    /// another, so a `began`→`lockOn` pair (or `lockOff`→`ended`) could execute out of order,
    /// making `markLocked()` fire before `beginRecording()` and silently drop the lock. Ordered,
    /// in-place delivery is load-bearing for the double-tap-lock upgrade (§2, M4).
    nonisolated func hotkeyManager(_ m: HotkeyManager, didEmit gesture: HotkeyGesture) {
        if Thread.isMainThread {
            // Common path: already on main (recognizer callback hops here first). Run synchronously
            // so ordering is exact.
            MainActor.assumeIsolated { dispatch(gesture) }
        } else {
            // Defensive path (e.g. the `emit` seam invoked off-main): DispatchQueue.main preserves
            // strict FIFO order between successive gestures — unlike unstructured `Task`s.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.dispatch(gesture) } }
        }
    }

    /// Synchronous, ordered gesture → coordinator mapping. Isolated to the MainActor and unit-testable.
    func dispatch(_ gesture: HotkeyGesture) {
        switch gesture {
        case .pushToTalkBegan:  coordinator.beginRecording(locked: false)
        case .pushToTalkEnded:  coordinator.endRecording()
        // A lock is `.pushToTalkBegan` then `.lockToggledOn` on the SAME live
        // session — upgrade in place, never restart (M4 note).
        case .lockToggledOn:    coordinator.markLocked()
        case .lockToggledOff:   coordinator.endRecording()
        case .cancel:           coordinator.cancelRecording()
        case .pasteLastTranscript: coordinator.pasteLast()
        // Triple-tap Left Option → surface the current microphone in a transient toast
        // (§ toasts-tripletap). Purely informational; recording is untouched.
        case .showMicrophone:   toastCenter.showMicrophone(currentMicrophoneName())
        }
    }

    /// Resolves the display name of the microphone Soro will record from: the device whose
    /// `uniqueID` matches `selectedMicrophoneUID`, else the system default input, else "Default
    /// microphone". Reads the selection from `PreferencesStore` and the name from AVFoundation.
    func currentMicrophoneName() -> String {
        let uid = preferencesStore.prefs.selectedMicrophoneUID
        if !uid.isEmpty {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            if let match = session.devices.first(where: { $0.uniqueID == uid }) {
                return match.localizedName
            }
        }
        if let def = AVCaptureDevice.default(for: .audio) {
            return def.localizedName
        }
        return "Default microphone"
    }
}
