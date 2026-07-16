import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - SettingsView

/// Settings dashboard panel (brief §4b / M8-Settings).
///
/// Sections:
///   • Microphone — AVCaptureDevice picker → prefs.selectedMicrophoneUID
///   • Hotkeys — display current bindings; key-capture field for the main trigger
///   • Transcription — Whisper model picker + download progress
///   • Cleanup — enable toggle, Ollama model name, Ollama status indicator
///   • Language — selectedLanguages single-select + auto-detect toggle
///   • Privacy — privacyMode, audioRecordingSounds
///   • General — launch at login, show menu-bar icon, hide bar when idle, cursorAutomaticEnter
///
/// Service dependencies injected as closures so the view compiles standalone
/// and can be driven by fakes in tests / previews.
struct SettingsView: View {

    // MARK: Injected stores (via EnvironmentObject from DashboardWindow)
    @EnvironmentObject private var prefsStore: PreferencesStore

    // MARK: Injected service closures (set via init; have sensible defaults)
    var transcriptionIsModelReady: (String) -> Bool
    /// Per-model on-disk install check (backed by `ModelManager.isModelInstalled`).
    var transcriptionIsModelInstalled: (String) -> Bool
    var transcriptionPrepareModel: (String, @escaping (Double) -> Void) async throws -> Void
    var cleanupIsAvailable: () async -> Bool
    /// Live-installed Ollama tags via `GET /api/tags` (empty when down).
    var ollamaInstalledModels: () async -> [String]
    /// Streams `POST /api/pull`; reports (fraction, status); returns success.
    var ollamaPull: (String, @escaping (Double?, String) -> Void) async -> Bool

    init(
        transcriptionIsModelReady: @escaping (String) -> Bool = { _ in false },
        transcriptionIsModelInstalled: @escaping (String) -> Bool = { _ in false },
        transcriptionPrepareModel: @escaping (String, @escaping (Double) -> Void) async throws -> Void = { _, _ in },
        cleanupIsAvailable: @escaping () async -> Bool = { false },
        ollamaInstalledModels: @escaping () async -> [String] = { [] },
        ollamaPull: @escaping (String, @escaping (Double?, String) -> Void) async -> Bool = { _, _ in false }
    ) {
        self.transcriptionIsModelReady = transcriptionIsModelReady
        self.transcriptionIsModelInstalled = transcriptionIsModelInstalled
        self.transcriptionPrepareModel = transcriptionPrepareModel
        self.cleanupIsAvailable = cleanupIsAvailable
        self.ollamaInstalledModels = ollamaInstalledModels
        self.ollamaPull = ollamaPull
    }

    // MARK: Body
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SoroTheme.Spacing.xl) {
                ScreenHeader(
                    title: "Settings",
                    subtitle: "Tune capture, transcription, cleanup, and privacy — everything stays on this Mac."
                )
                MicrophoneSection()
                HotkeysSection()
                TranscriptionSection(
                    isModelReady: transcriptionIsModelReady,
                    isModelInstalled: transcriptionIsModelInstalled,
                    prepareModel: transcriptionPrepareModel
                )
                VoiceDetectionSection()
                CleanupSection(
                    isAvailable: cleanupIsAvailable,
                    installedModels: ollamaInstalledModels,
                    pullModel: ollamaPull
                )
                LanguageSection()
                PrivacySection()
                GeneralSection()
            }
            .padding(SoroTheme.Spacing.screen)
        }
        .background(SoroTheme.canvas)
        .environmentObject(prefsStore)
    }
}

// MARK: - Helpers

/// A labelled section card.
private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AccentIconTile(systemImage: systemImage, size: 28, symbolSize: 13)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SoroTheme.textPrimary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .soroCard(padding: SoroTheme.Spacing.xl)
    }
}

/// A row with a fixed-width label on the left and content on the right.
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .frame(width: 160, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.callout)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Microphone Section

private struct MicrophoneSection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    @State private var availableMics: [AVCaptureDevice] = []

    var body: some View {
        SettingsCard(title: "Microphone", systemImage: "mic") {
            SettingsRow(label: "Input device") {
                Picker("", selection: Binding(
                    get: { prefsStore.prefs.selectedMicrophoneUID },
                    set: { prefsStore.prefs.selectedMicrophoneUID = $0; prefsStore.save() }
                )) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(availableMics, id: \.uniqueID) { mic in
                        Text(mic.localizedName).tag(mic.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
            }
        }
        .task { availableMics = fetchMicrophones() }
    }

    private func fetchMicrophones() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices
    }
}

// MARK: - Hotkeys Section

private struct HotkeysSection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    var body: some View {
        SettingsCard(title: "Hotkeys", systemImage: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(label: "Main trigger") {
                    HotkeyRecorderField(
                        hotkeyData: Binding(
                            get: { prefsStore.prefs.hotkeyData },
                            set: { prefsStore.prefs.hotkeyData = $0
                                   prefsStore.prefs.selectedHotkey = $0
                                   prefsStore.save() }
                        )
                    )
                }

                SettingsRow(label: "Hands-free toggle") {
                    HotkeyBadge(hotkeys: prefsStore.prefs.handsFreeModeHotkeyDataArray)
                    Text("(read-only)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                SettingsRow(label: "Paste last transcript") {
                    HotkeyBadge(hotkeys: prefsStore.prefs.pasteTranscriptHotkeyDataArray)
                    Text("(read-only)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                SettingsRow(label: "Command mode") {
                    HotkeyBadge(hotkeys: prefsStore.prefs.commandModeHotkeyDataArray)
                    Text("(read-only)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("Click the main trigger field and press a key or modifier to rebind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 172)
            }
        }
    }
}

/// Displays existing hotkey data as a small badge row.
private struct HotkeyBadge: View {
    let hotkeys: [HotkeyData]

    var body: some View {
        Group {
            if hotkeys.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(hotkeys.enumerated()), id: \.offset) { _, h in
                        Text(h.keyName)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(NSColor.controlColor))
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Color(NSColor.separatorColor)))
                            )
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }
}

/// An interactive key-capture field for the main trigger.
/// Click to enter capture mode; the next key-down / flags-changed event becomes the new binding.
private struct HotkeyRecorderField: View {
    @Binding var hotkeyData: HotkeyData
    @State private var isCapturing = false

    var body: some View {
        Button(action: { isCapturing.toggle() }) {
            HStack(spacing: 6) {
                if isCapturing {
                    Text("Press a key…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(SoroTheme.accent)
                } else {
                    Text(hotkeyData.keyName)
                        .font(.system(.caption, design: .monospaced))
                }
                Image(systemName: isCapturing ? "xmark.circle.fill" : "pencil")
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCapturing
                          ? SoroTheme.accent.opacity(0.12)
                          : Color(NSColor.controlColor))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isCapturing ? SoroTheme.accent : Color(NSColor.separatorColor),
                                      lineWidth: isCapturing ? 1.5 : 0.5))
            )
        }
        .buttonStyle(.plain)
        .overlay(
            // Invisible NSEvent capture overlay when in capturing mode
            Group {
                if isCapturing {
                    HotkeyCaptureClearTarget { captured in
                        hotkeyData = captured
                        isCapturing = false
                    } onCancel: {
                        isCapturing = false
                    }
                }
            }
        )
    }
}

/// SwiftUI wrapper that installs a local NSEvent monitor to capture the next keypress.
private struct HotkeyCaptureClearTarget: NSViewRepresentable {
    let onCapture: (HotkeyData) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator {
        var monitor: Any?
        let onCapture: (HotkeyData) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (HotkeyData) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            installMonitor()
        }

        deinit { removeMonitor() }

        private func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .flagsChanged]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown && event.keyCode == 53 {
                    // Escape cancels
                    self.removeMonitor()
                    DispatchQueue.main.async { self.onCancel() }
                    return nil
                }
                let captured = HotkeyData.from(event: event)
                self.removeMonitor()
                DispatchQueue.main.async { self.onCapture(captured) }
                return nil
            }
        }

        private func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}

// MARK: - Transcription Section

private struct TranscriptionSection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    let isModelReady: (String) -> Bool
    let isModelInstalled: (String) -> Bool
    let prepareModel: (String, @escaping (Double) -> Void) async throws -> Void

    /// Curated catalogue (fastest → most accurate). Extend via `ModelManager.curatedModels`.
    private let models = ModelManager.curatedModels

    // Per-model download bookkeeping keyed by model id.
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadError: [String: String] = [:]
    // Bumped after a download completes so install badges re-evaluate.
    @State private var installTick = 0

    private var selected: String { prefsStore.prefs.whisperModel }

    var body: some View {
        SettingsCard(title: "Transcription", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pick the Whisper model used for on-device speech-to-text. Larger models are more accurate but slower to download and run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(models) { model in
                    modelRow(model)
                    if model.id != models.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModelOption) -> some View {
        let isSelected = model.id == selected
        // Reference installTick so SwiftUI recomputes install state after a download.
        let _ = installTick
        let installed = isModelInstalled(model.id)
        let progress = downloadProgress[model.id]
        let error = downloadError[model.id]

        HStack(alignment: .top, spacing: 12) {
            Button {
                prefsStore.prefs.whisperModel = model.id
                prefsStore.save()
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? SoroTheme.accent : .secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Selected model" : "Use this model")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SoroTheme.textPrimary)
                    Text(model.sizeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isSelected {
                        Text("Active")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(SoroTheme.accent.opacity(0.15)))
                            .foregroundStyle(SoroTheme.accent)
                    }
                }
                Text(model.qualityHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Label(error, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 0)

            // Trailing status / action.
            Group {
                if let progress {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                        Text(String(format: "%.0f%%", progress * 100))
                            .monospacedDigit()
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if installed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Installed").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else {
                    Button("Download") { startDownload(model.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(SoroTheme.accent)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func startDownload(_ modelID: String) {
        downloadProgress[modelID] = 0
        downloadError[modelID] = nil
        Task {
            do {
                try await prepareModel(modelID) { p in
                    Task { @MainActor in downloadProgress[modelID] = p }
                }
                await MainActor.run {
                    downloadProgress[modelID] = nil
                    installTick += 1
                }
            } catch {
                await MainActor.run {
                    downloadProgress[modelID] = nil
                    downloadError[modelID] = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Voice Detection Section

private struct VoiceDetectionSection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    /// Resolved sensitivity — falls back to 0.5 when the optional JSON key is absent (§6 compat).
    private var sensitivity: Double {
        prefsStore.prefs.vadSensitivity ?? 0.5
    }

    var body: some View {
        SettingsCard(title: "Voice detection", systemImage: "waveform.badge.mic") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(label: "Sensitivity") {
                    HStack(spacing: 10) {
                        Text("Filter silence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        Slider(
                            value: Binding(
                                get: { sensitivity },
                                set: { newVal in
                                    prefsStore.prefs.vadSensitivity = newVal
                                    prefsStore.save()
                                }
                            ),
                            in: 0...1
                        )
                        .frame(maxWidth: 200)
                        Text("Keep everything")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                    }
                }

                SettingsRow(label: "") {
                    Text(sensitivityDescription(sensitivity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Live preview: as sensitivity DROPS (toward "filter silence"),
                // more filler/short words get struck through, showing the effect.
                VADPreview(sensitivity: sensitivity)
                    .padding(.top, 2)
            }
        }
    }

    private func sensitivityDescription(_ value: Double) -> String {
        switch value {
        case ..<0.25:
            return "Aggressive — long pauses and background noise are filtered out."
        case 0.25..<0.6:
            return "Balanced — moderate silence filtering (recommended)."
        case 0.6..<0.85:
            return "Permissive — most speech kept; only clear silence dropped."
        default:
            return "Maximum — all audio kept, including short ad-libs like 'Yo.'"
        }
    }
}

/// Animated preview of the VAD filter. Each sample sentence has words tagged with
/// a "keepThreshold" (0…1): fillers/hesitations have a high threshold so they're
/// the first to be struck through as sensitivity drops toward "filter silence".
/// A word is struck when `sensitivity < keepThreshold`.
private struct VADPreview: View {
    let sensitivity: Double

    // (word, keepThreshold). Higher threshold = filtered sooner (more aggressive).
    private static let samples: [[(String, Double)]] = [
        [("Um,",0.9),("so",0.55),("let's",0.15),("ship",0.1),("it",0.12),("today",0.14)],
        [("Yeah",0.85),("I",0.2),("think",0.35),("the",0.3),("build",0.1),("passed",0.12)],
        [("Uh",0.92),("can",0.2),("you",0.22),("send",0.12),("the",0.4),("report",0.1),("please",0.5)],
        [("Like,",0.88),("basically",0.75),("we",0.25),("need",0.15),("more",0.3),("tests",0.1)],
        [("Yo.",0.6),("wait",0.7),("actually",0.65),("push",0.12),("to",0.4),("main",0.1)],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.samples.enumerated()), id: \.offset) { _, sentence in
                sentenceView(sentence)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.25), value: sensitivity)
    }

    private func sentenceView(_ sentence: [(String, Double)]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(sentence.enumerated()), id: \.offset) { _, item in
                let struck = sensitivity < item.1
                Text(item.0)
                    .font(.system(size: 12, weight: struck ? .regular : .medium))
                    .strikethrough(struck, color: .secondary)
                    .foregroundStyle(struck ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.9))
                    .scaleEffect(struck ? 0.96 : 1, anchor: .leading)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Cleanup Section

private struct CleanupSection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    let isAvailable: () async -> Bool
    let installedModels: () async -> [String]
    let pullModel: (String, @escaping (Double?, String) -> Void) async -> Bool

    @State private var ollamaAvailable: Bool? = nil  // nil = checking
    @State private var installed: [String] = []
    // Pull bookkeeping keyed by model tag.
    @State private var pullFraction: [String: Double?] = [:]   // present ⇒ pulling
    @State private var pullStatus: [String: String] = [:]
    @State private var pullError: [String: String] = [:]

    /// Curated options merged with any live-installed tags not already curated.
    private var options: [OllamaModelOption] {
        var result = OllamaClient.curatedModels
        let curatedIDs = Set(result.map(\.id))
        for tag in installed where !curatedIDs.contains(tag)
            && !curatedIDs.contains(OllamaClient.normalizeTag(tag)) {
            result.append(OllamaModelOption(id: tag, label: tag, hint: "Installed locally"))
        }
        return result
    }

    private var selected: String { prefsStore.prefs.ollamaModel }

    var body: some View {
        SettingsCard(title: "Cleanup (Ollama)", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Enable cleanup") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.cleanupEnabled },
                        set: { prefsStore.prefs.cleanupEnabled = $0; prefsStore.save() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text(prefsStore.prefs.cleanupEnabled
                         ? "Ollama cleans up transcripts"
                         : "Raw transcripts inserted without cleanup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                statusRow

                Divider().opacity(0.4)

                Text("Cleanup model")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(options) { model in
                    modelRow(model)
                    if model.id != options.last?.id { Divider().opacity(0.3) }
                }
            }
        }
        .task { await refresh() }
    }

    private var statusRow: some View {
        SettingsRow(label: "Ollama status") {
            Group {
                switch ollamaAvailable {
                case nil:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                case .some(true):
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Running").foregroundStyle(.secondary)
                    }
                case .some(false):
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Unavailable — run: brew install ollama && ollama serve")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-check Ollama & installed models")
        }
    }

    @ViewBuilder
    private func modelRow(_ model: OllamaModelOption) -> some View {
        let isSelected = model.id == selected
        let isInstalled = OllamaClient.isInstalled(model.id, in: installed)
        let fraction = pullFraction[model.id]        // Optional<Optional<Double>>
        let isPulling = fraction != nil
        let error = pullError[model.id]

        HStack(alignment: .top, spacing: 12) {
            Button {
                prefsStore.prefs.ollamaModel = model.id
                prefsStore.save()
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? SoroTheme.accent : .secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Selected model" : "Use this model")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SoroTheme.textPrimary)
                    Text(model.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if isSelected {
                        Text("Active")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(SoroTheme.accent.opacity(0.15)))
                            .foregroundStyle(SoroTheme.accent)
                    }
                }
                Text(model.hint).font(.caption).foregroundStyle(.secondary)
                if isPulling, let status = pullStatus[model.id], !status.isEmpty {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
                if let error {
                    Label(error, systemImage: "xmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Spacer(minLength: 0)

            Group {
                if isPulling {
                    if let frac = fraction ?? nil {
                        VStack(alignment: .trailing, spacing: 4) {
                            ProgressView(value: frac).progressViewStyle(.linear).frame(width: 120)
                            Text(String(format: "%.0f%%", frac * 100))
                                .monospacedDigit().font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Pulling…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if isInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Installed").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else if ollamaAvailable == true {
                    Button("Pull") { startPull(model.id) }
                        .buttonStyle(.bordered).controlSize(.small).tint(SoroTheme.accent)
                } else {
                    // Ollama down: can't pull, so surface the exact command.
                    Text("Run: ollama pull \(model.id)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func refresh() async {
        ollamaAvailable = nil
        let up = await isAvailable()
        let models = up ? await installedModels() : []
        await MainActor.run {
            ollamaAvailable = up
            installed = models
        }
    }

    private func startPull(_ tag: String) {
        pullFraction[tag] = .some(nil)   // pulling, no % yet
        pullStatus[tag] = "starting…"
        pullError[tag] = nil
        Task {
            let ok = await pullModel(tag) { frac, status in
                Task { @MainActor in
                    pullFraction[tag] = .some(frac)
                    pullStatus[tag] = status
                }
            }
            await MainActor.run {
                pullFraction[tag] = nil
                pullStatus[tag] = nil
                if !ok { pullError[tag] = "Pull failed — try 'ollama pull \(tag)' in Terminal." }
            }
            await refresh()
        }
    }
}

// MARK: - Language Section

private let kSupportedLanguages: [(code: String, name: String)] = [
    ("en", "English"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("nl", "Dutch"),
    ("pl", "Polish"),
    ("ru", "Russian"),
    ("ja", "Japanese"),
    ("zh", "Chinese"),
    ("ko", "Korean"),
    ("ar", "Arabic"),
    ("hi", "Hindi"),
    ("tr", "Turkish"),
]

private struct LanguageSection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    /// Single-select for now (brief §4b): selectedLanguages is an array but we pick one.
    var selectedLanguage: String {
        prefsStore.prefs.selectedLanguages.first ?? "en"
    }

    var body: some View {
        SettingsCard(title: "Language", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(label: "Transcription language") {
                    Picker("", selection: Binding(
                        get: { selectedLanguage },
                        set: { code in
                            prefsStore.prefs.selectedLanguages = [code]
                            prefsStore.save()
                        }
                    )) {
                        ForEach(kSupportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    .disabled(prefsStore.prefs.isAutoDetectLanguage)
                }

                SettingsRow(label: "Auto-detect language") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.isAutoDetectLanguage },
                        set: { prefsStore.prefs.isAutoDetectLanguage = $0; prefsStore.save() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text("Whisper will detect the spoken language automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Privacy Section

private struct PrivacySection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    var body: some View {
        SettingsCard(title: "Privacy", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(label: "Privacy mode") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.privacyMode },
                        set: { prefsStore.prefs.privacyMode = $0; prefsStore.save() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text("Delete the audio recording immediately after transcription")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: "Recording sounds") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.audioRecordingSounds },
                        set: { prefsStore.prefs.audioRecordingSounds = $0; prefsStore.save() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text("Play start and stop tones")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Privacy assurance note
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(SoroTheme.accent)
                    Text("100% on-device — your voice never leaves this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 172)
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - General Section

private struct GeneralSection: View {
    @EnvironmentObject private var prefsStore: PreferencesStore

    @State private var launchAtLoginError: String? = nil

    var body: some View {
        SettingsCard(title: "General", systemImage: "gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(label: "Launch at login") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.launchAtLogin },
                        set: { newVal in
                            applyLaunchAtLogin(newVal)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    if let err = launchAtLoginError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                SettingsRow(label: "Show menu-bar icon") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.showMenuBarIcon },
                        set: { prefsStore.prefs.showMenuBarIcon = $0; prefsStore.save() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                SettingsRow(label: "Hide bar when idle") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.hideBarWhenIdle },
                        set: { prefsStore.prefs.hideBarWhenIdle = $0
                               prefsStore.prefs.hideBar = $0
                               prefsStore.save() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text("The recording bar collapses when not recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: "Auto-press Return") {
                    Toggle("", isOn: Binding(
                        get: { prefsStore.prefs.cursorAutomaticEnter },
                        set: { prefsStore.prefs.cursorAutomaticEnter = $0; prefsStore.save() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text("Press Return automatically after inserting text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        launchAtLoginError = nil
        do {
            // SMAppService.mainApp throws when called from a Debug build that is not
            // registered as a Login Item in the target's entitlements. The toggle
            // shows the error text inline instead of crashing (M9 §6).
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            prefsStore.prefs.launchAtLogin = enable
            prefsStore.save()
        } catch {
            // Surface the error in the UI — common in Debug builds.
            launchAtLoginError = "Could not \(enable ? "register" : "unregister"): \(error.localizedDescription)"
            // Do NOT update the pref value when the SMAppService call failed.
        }
    }
}

// MARK: - HotkeyData convenience

private extension HotkeyData {
    /// Builds a HotkeyData from an NSEvent (keyDown or flagsChanged).
    static func from(event: NSEvent) -> HotkeyData {
        let isModifierOnly = event.type == .flagsChanged
        let keyName: String
        if isModifierOnly {
            switch event.keyCode {
            case 58: keyName = "Left Option"
            case 61: keyName = "Right Option"
            case 55: keyName = "Left Command"
            case 54: keyName = "Right Command"
            case 56: keyName = "Left Shift"
            case 60: keyName = "Right Shift"
            case 59: keyName = "Left Control"
            case 62: keyName = "Right Control"
            default: keyName = "Key \(event.keyCode)"
            }
        } else {
            keyName = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        }

        return HotkeyData(
            keyCode: event.keyCode,
            keyName: keyName,
            isModifierOnlyTrigger: isModifierOnly,
            isRightModifier: [61, 54, 60, 62].contains(event.keyCode),
            additionalModifiers: [],
            nonModifierKeys: isModifierOnly ? [] : [event.keyCode],
            modifiers: UInt64(event.modifierFlags.rawValue),
            isMouseButton: false,
            mouseButton: 0
        )
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static let prefsStore: PreferencesStore = {
        let s = PreferencesStore(paths: .live)
        return s
    }()

    static var previews: some View {
        SettingsView(
            transcriptionIsModelReady: { _ in true },
            transcriptionIsModelInstalled: { $0 == "openai_whisper-small.en" },
            transcriptionPrepareModel: { _, _ in },
            cleanupIsAvailable: { true },
            ollamaInstalledModels: { ["llama3.2:3b"] },
            ollamaPull: { _, _ in true }
        )
        .environmentObject(prefsStore)
        .frame(width: 700, height: 700)
    }
}
#endif
