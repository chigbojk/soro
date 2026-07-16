import SwiftUI
import Combine

/// Sidebar sections (brief §4b). "Team" is intentionally dropped.
enum DashboardSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case dictionary = "Dictionary"
    case styleMatching = "Style Matching"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home:          return "house"
        case .dictionary:    return "character.book.closed"
        case .styleMatching: return "wand.and.stars"
        case .settings:      return "gearshape"
        }
    }
}

/// Small shared selection holder so the menu can deep-link to Settings.
@MainActor
final class DashboardSelection: ObservableObject {
    static let shared = DashboardSelection()
    @Published var selected: DashboardSection = .home
}

/// The main dashboard window shell: left sidebar + detail (brief §4b).
/// M1 ships the shell with placeholder detail views ("coming in M8").
struct DashboardWindow: View {
    static let windowID = "dashboard"

    @ObservedObject private var selection = DashboardSelection.shared
    @EnvironmentObject private var appState: AppState

    // Audio preview player — shared across HomeView rows (M9 §4).
    @StateObject private var audioPlayer = AudioPreviewPlayer()

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: Binding(
                get: { selection.selected },
                set: { selection.selected = $0 ?? .home })) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(200)
            .listStyle(.sidebar)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 460)
                .background(SoroTheme.canvas)
        }
        .frame(minWidth: 820, minHeight: 560)
        .tint(SoroTheme.accent)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection.selected {
        case .home:
            HomeView(
                onReinsert: { [weak appState] transcript in
                    // Re-insert this transcript's text at the cursor (M3).
                    Task { await appState?.insertion.insert(transcript.text) }
                },
                onPlayAudio: { [weak audioPlayer] transcript in
                    // Audio preview — play/pause recorded audio (M9 §4).
                    guard let url = transcript.audioURL else { return }
                    audioPlayer?.toggle(id: transcript.id, url: url)
                }
            )
        case .dictionary:    DictionaryView()
        case .styleMatching: StyleMatchingView()
        case .settings:
            SettingsView(
                transcriptionIsModelReady: { [weak appState] _ in
                    appState?.transcription.isModelReady ?? false
                },
                transcriptionIsModelInstalled: { name in
                    ModelManager(paths: .live).isModelInstalled(name)
                },
                transcriptionPrepareModel: { [weak appState] name, progress in
                    try await appState?.transcription.prepareModel(name, progress: progress)
                },
                cleanupIsAvailable: { [weak appState] in
                    await appState?.cleanup.isAvailable() ?? false
                },
                ollamaInstalledModels: {
                    await OllamaClient(model: "").installedModels()
                },
                ollamaPull: { tag, progress in
                    await OllamaClient(model: tag).pullModel(tag, progress: progress)
                })
        }
    }
}

/// Placeholder shown for detail views that arrive in later milestones.
struct PlaceholderDetail: View {
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 40))
                .foregroundStyle(SoroTheme.accent)
            Text(title).font(.title2).bold()
            Text(note).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
