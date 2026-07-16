import SwiftUI
import AppKit

@main
struct SoroApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(SoroAppDelegate.self) private var delegate

    init() {
        // Menu-bar accessory app — no Dock icon (brief App A).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Menu-bar item — icon reflects recording state.
        MenuBarExtra("Soro", systemImage: menuBarIcon) {
            MenuBarMenu(coordinator: appState.coordinator)
                .environmentObject(appState)
                .onAppear {
                    // Open onboarding on first launch (once menus are ready).
                    if appState.showOnboarding {
                        delegate.openOnboardingIfNeeded(appState: appState)
                    }
                }
        }
        .menuBarExtraStyle(.menu)

        // Dashboard window, opened on demand.
        Window("Soro", id: DashboardWindow.windowID) {
            DashboardWindow()
                .environmentObject(appState)
                .environmentObject(appState.preferencesStore)
                .environmentObject(appState.transcriptStore)
                .environmentObject(appState.glossaryStore)
                .environmentObject(appState.personalizationStore)
                .environmentObject(appState.statsStore)
                .environmentObject(appState.autoDictionaryStore)
                .onAppear { appState.startServices() }
        }
        .windowResizability(.contentSize)
    }

    /// Menu bar icon name — changes with recording state.
    private var menuBarIcon: String {
        switch appState.coordinator.state {
        case .recording: return "waveform.badge.mic"
        case .transcribing, .inserting: return "ellipsis.circle"
        default: return "waveform"
        }
    }
}

// MARK: - App Delegate

/// Handles first-launch onboarding window (M9) and launch-at-login state.
final class SoroAppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var onboardingShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nothing extra needed here; onboarding is opened from body.
    }

    /// Opens the onboarding NSWindow once if not yet shown. Safe to call multiple times.
    @MainActor
    func openOnboardingIfNeeded(appState: AppState) {
        guard !onboardingShown, appState.showOnboarding else { return }
        onboardingShown = true
        appState.startServices()

        let view = OnboardingView(
            onComplete: { [weak self] in
                appState.dismissOnboarding()
                self?.onboardingWindow?.close()
            },
            retryHotkey: { appState.retryHotkey() },
            modelManager: ModelManager(paths: .live),
            prepareModel: { name, progress in
                try await appState.transcription.prepareModel(name, progress: progress)
            }
        )
        .environmentObject(appState.preferencesStore)
        .environmentObject(appState.transcriptStore)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Soro"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}
