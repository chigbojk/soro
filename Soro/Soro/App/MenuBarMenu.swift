import SwiftUI

/// The contents of the `MenuBarExtra` menu (brief §4a/§4b, M9 §5).
struct MenuBarMenu: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var coordinator: DictationCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // State indicator
        Text(stateLine)
            .font(.caption)

        // Accessibility warning — shown when hotkey is inactive (M9 §5).
        if appState.hotkeyInactive {
            Divider()
            Button {
                openAccessibilitySettings()
            } label: {
                Label("Grant Accessibility…", systemImage: "exclamationmark.shield.fill")
            }
        }

        Divider()

        Button(startStopTitle) { toggleDictation() }

        Divider()

        Button("Open Dashboard") { openWindow(id: DashboardWindow.windowID) }
        Button("Settings…") {
            openWindow(id: DashboardWindow.windowID)
            DashboardSelection.shared.selected = .settings
        }

        Divider()

        Button("Quit Soro") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: - State display

    private var stateLine: String {
        if appState.hotkeyInactive {
            return "Hotkey inactive — Accessibility needed"
        }
        switch coordinator.state {
        case .idle:                 return "Ready — hold Option to dictate"
        case .recording(let lock):  return lock ? "Recording (locked)…" : "Recording…"
        case .transcribing:         return "Transcribing…"
        case .inserting:            return "Inserting…"
        case .done:                 return "Done"
        case .error(let msg):       return "Error: \(msg)"
        }
    }

    private var startStopTitle: String {
        if case .idle = coordinator.state { return "Start Dictation" }
        return "Stop Dictation"
    }

    // MARK: - Actions

    private func toggleDictation() {
        switch coordinator.state {
        case .idle:      coordinator.beginRecording(locked: false)
        case .recording: coordinator.endRecording()
        default:         break
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
