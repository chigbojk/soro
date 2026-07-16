import SwiftUI
import AVFoundation
import ApplicationServices

// MARK: - OnboardingView

/// Multi-step first-run flow (brief §4c, M9).
///
/// Steps:
///   0. Welcome — privacy highlights
///   1. Microphone permission
///   2. Accessibility permission (polls AXIsProcessTrusted every 2s; auto-advances on grant)
///   3. Whisper model download
///   4. Ollama check (skippable)
///   5. Practice dictation — hold Left Option, see live transcript
///   6. Done
///
/// Shown on first launch (`prefs.hasCompletedOnboarding` == false/nil).
/// Each step has a Skip button; completing step 6 (or Skip) sets the flag.
struct OnboardingView: View {

    // MARK: Dependencies

    @EnvironmentObject private var prefsStore: PreferencesStore
    @EnvironmentObject private var transcriptStore: TranscriptStore

    /// Called when onboarding finishes (either completed or skipped).
    var onComplete: () -> Void = {}

    /// Injected so the onboarding can retry the hotkey tap after Accessibility is granted.
    var retryHotkey: () -> Void = {}

    /// Model manager — injected for testability; defaults to production path.
    var modelManager: ModelManager = ModelManager(paths: .live)

    /// Closure called to prepare a Whisper model (mirrors `TranscriptionService.prepareModel`).
    var prepareModel: (String, @escaping (Double) -> Void) async throws -> Void = { _, _ in }

    // MARK: Step index

    @State private var step: Int = 0
    private let totalSteps = 7   // 0-indexed steps 0…6

    // MARK: Body

    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.05, blue: 0.14),
                    Color(red: 0.10, green: 0.09, blue: 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                progressBar
                    .padding(.top, 32)
                    .padding(.bottom, 28)

                // Step content
                Group {
                    switch step {
                    case 0: WelcomeStep(onNext: nextStep, onSkip: skipAll)
                    case 1: MicPermissionStep(onNext: nextStep, onSkip: nextStep)
                    case 2: AccessibilityStep(
                                onNext: nextStep,
                                onSkip: nextStep,
                                retryHotkey: retryHotkey)
                    case 3: ModelDownloadStep(
                                prefsStore: prefsStore,
                                modelManager: modelManager,
                                prepareModel: prepareModel,
                                onNext: nextStep,
                                onSkip: nextStep)
                    case 4: OllamaStep(onNext: nextStep, onSkip: nextStep)
                    case 5: PracticeStep(
                                transcriptStore: transcriptStore,
                                onNext: nextStep,
                                onSkip: nextStep)
                    default: DoneStep(onFinish: finish)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 500)
    }

    // MARK: Progress indicator

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? SoroTheme.accent : Color.white.opacity(0.2))
                    .frame(width: i == step ? 24 : 8, height: 6)
                    .animation(.spring(response: 0.35), value: step)
            }
        }
    }

    // MARK: Navigation

    private func nextStep() {
        withAnimation(.easeInOut(duration: 0.2)) {
            step = min(step + 1, totalSteps - 1)
        }
    }

    private func skipAll() {
        finish()
    }

    private func finish() {
        prefsStore.prefs.hasCompletedOnboarding = true
        prefsStore.save()
        onComplete()
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    private let pillars: [(String, String)] = [
        ("lock.shield.fill",      "100% on-device"),
        ("person.slash.fill",     "No accounts"),
        ("antenna.radiowaves.left.and.right.slash", "No telemetry"),
    ]

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(SoroTheme.accent)

                Text("Welcome to Soro")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Instant dictation — powered entirely by your Mac.\nYour voice never leaves this device.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 20) {
                ForEach(pillars, id: \.0) { icon, label in
                    VStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .foregroundStyle(SoroTheme.accent)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 100)
                }
            }

            OnboardingNavRow(
                primaryLabel: "Get Started",
                primaryAction: onNext,
                skipLabel: "Skip Setup",
                skipAction: onSkip
            )
        }
        .padding(.horizontal, 48)
    }
}

// MARK: - Step 1: Microphone

private struct MicPermissionStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    @State private var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var polling = false

    var body: some View {
        VStack(spacing: 28) {
            OnboardingStepHeader(
                icon: "mic.fill",
                title: "Microphone Access",
                subtitle: "Soro needs your mic to capture speech.\nYour audio is processed on-device only."
            )

            statusBadge

            OnboardingNavRow(
                primaryLabel: status == .authorized ? "Continue" : "Grant Access",
                primaryAction: {
                    if status == .authorized {
                        onNext()
                    } else {
                        requestMic()
                    }
                },
                skipLabel: "Skip",
                skipAction: onSkip
            )
        }
        .padding(.horizontal, 48)
        .onAppear { refreshStatus() }
    }

    private var statusBadge: some View {
        Group {
            switch status {
            case .authorized:
                OnboardingStatusBadge(icon: "checkmark.circle.fill", label: "Microphone access granted", color: .green)
            case .denied, .restricted:
                OnboardingStatusBadge(icon: "xmark.circle.fill", label: "Access denied — open System Settings > Privacy > Microphone", color: .red)
            default:
                OnboardingStatusBadge(icon: "clock", label: "Tap below to request access", color: .orange)
            }
        }
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                refreshStatus()
                if granted { onNext() }
            }
        }
    }

    private func refreshStatus() {
        status = AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

// MARK: - Step 2: Accessibility

private struct AccessibilityStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void
    let retryHotkey: () -> Void

    @State private var trusted: Bool = AXIsProcessTrusted()
    @State private var pollingTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 28) {
            OnboardingStepHeader(
                icon: "accessibility",
                title: "Accessibility Access",
                subtitle: "Required for the global hotkey that works in any app.\nOnly local key events are monitored — nothing is sent anywhere."
            )

            if trusted {
                OnboardingStatusBadge(icon: "checkmark.circle.fill", label: "Accessibility access granted", color: .green)
            } else {
                OnboardingStatusBadge(icon: "exclamationmark.shield.fill", label: "Access not yet granted — tap below to open System Settings", color: .orange)
            }

            OnboardingNavRow(
                primaryLabel: trusted ? "Continue" : "Open System Settings",
                primaryAction: {
                    if trusted {
                        onNext()
                    } else {
                        openAccessibilitySettings()
                        startPolling()
                    }
                },
                skipLabel: "Skip",
                skipAction: {
                    pollingTask?.cancel()
                    onSkip()
                }
            )
        }
        .padding(.horizontal, 48)
        .onAppear { startPolling() }
        .onDisappear { pollingTask?.cancel() }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        guard !trusted else { return }
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let nowTrusted = AXIsProcessTrusted()
                await MainActor.run {
                    trusted = nowTrusted
                    if nowTrusted {
                        retryHotkey()
                        pollingTask?.cancel()
                        onNext()
                    }
                }
            }
        }
    }
}

// MARK: - Step 3: Model Download

private struct ModelDownloadStep: View {
    let prefsStore: PreferencesStore
    let modelManager: ModelManager
    let prepareModel: (String, @escaping (Double) -> Void) async throws -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    @State private var selectedModel: String = ModelManager.defaultModel
    @State private var isDownloading = false
    @State private var progress: Double = 0
    @State private var errorMessage: String? = nil

    private let modelLabels: [String: String] = [
        "openai_whisper-base.en":   "Base — fastest (~75 MB, English)",
        "openai_whisper-base":      "Base — fastest (~75 MB, multilingual)",
        "openai_whisper-small.en":  "Small — balanced (~244 MB, English)",
        "openai_whisper-small":     "Small — balanced (~244 MB, multilingual)",
        "openai_whisper-medium.en": "Medium — most accurate (~769 MB, English)",
    ]

    private var isReady: Bool {
        modelManager.isModelInstalled(selectedModel)
    }

    var body: some View {
        VStack(spacing: 28) {
            OnboardingStepHeader(
                icon: "arrow.down.circle.fill",
                title: "Download Whisper Model",
                subtitle: "Choose the on-device speech model.\nBase is recommended for most users."
            )

            VStack(spacing: 12) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(ModelManager.availableModels, id: \.self) { m in
                        Text(modelLabels[m] ?? m).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)
                .disabled(isDownloading)

                if isDownloading {
                    VStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 320)
                            .tint(SoroTheme.accent)
                        Text(String(format: "Downloading… %.0f%%", progress * 100))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else if isReady {
                    OnboardingStatusBadge(icon: "checkmark.circle.fill", label: "Model ready", color: .green)
                } else {
                    OnboardingStatusBadge(icon: "icloud.and.arrow.down", label: "Not downloaded — tap below to download", color: .orange)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }

            OnboardingNavRow(
                primaryLabel: isReady ? "Continue" : (isDownloading ? "Downloading…" : "Download"),
                primaryAction: {
                    if isReady {
                        prefsStore.prefs.whisperModel = selectedModel
                        prefsStore.save()
                        onNext()
                    } else {
                        startDownload()
                    }
                },
                skipLabel: "Skip",
                skipAction: onSkip,
                primaryDisabled: isDownloading
            )
        }
        .padding(.horizontal, 48)
    }

    private func startDownload() {
        isDownloading = true
        progress = 0
        errorMessage = nil
        Task {
            do {
                try await prepareModel(selectedModel) { p in
                    Task { @MainActor in progress = p }
                }
                await MainActor.run {
                    isDownloading = false
                    prefsStore.prefs.whisperModel = selectedModel
                    prefsStore.save()
                    onNext()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Step 4: Ollama

private struct OllamaStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    enum OllamaState { case checking, running, down }
    @State private var state: OllamaState = .checking

    var body: some View {
        VStack(spacing: 28) {
            OnboardingStepHeader(
                icon: "sparkles",
                title: "Ollama (Optional)",
                subtitle: "Cleanup and style matching use a local LLM via Ollama.\nRaw mode works great even without it."
            )

            Group {
                switch state {
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking for Ollama…").foregroundStyle(.white.opacity(0.7))
                    }
                case .running:
                    OnboardingStatusBadge(icon: "checkmark.circle.fill", label: "Ollama is running", color: .green)
                case .down:
                    VStack(alignment: .leading, spacing: 10) {
                        OnboardingStatusBadge(icon: "xmark.circle.fill", label: "Ollama not found", color: .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("To install:")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                            CodeSnippet("brew install ollama")
                            CodeSnippet("ollama pull llama3.2:3b")
                            CodeSnippet("ollama serve")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            OnboardingNavRow(
                primaryLabel: state == .running ? "Continue" : "Continue Anyway",
                primaryAction: onNext,
                skipLabel: "Skip",
                skipAction: onSkip
            )
        }
        .padding(.horizontal, 48)
        .task { await check() }
    }

    private func check() async {
        state = .checking
        let reachable = await OllamaClient().isReachable()
        state = reachable ? .running : .down
    }
}

// MARK: - Step 5: Practice

private struct PracticeStep: View {
    let transcriptStore: TranscriptStore
    let onNext: () -> Void
    let onSkip: () -> Void

    @State private var initialCount: Int = 0
    @State private var succeeded = false
    @State private var pollingTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 28) {
            OnboardingStepHeader(
                icon: "hand.tap.fill",
                title: "Try It Out",
                subtitle: "Hold Left Option and say something.\nThe transcript will appear below."
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                        succeeded ? Color.green.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1))
                    .frame(height: 100)

                if succeeded {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Dictation received!")
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                        Text("You're all set.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(12)
                } else {
                    Text("Waiting for dictation…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(12)
                }
            }
            .frame(maxWidth: 380)

            OnboardingNavRow(
                primaryLabel: succeeded ? "Continue" : "Continue",
                primaryAction: {
                    pollingTask?.cancel()
                    onNext()
                },
                skipLabel: "Skip",
                skipAction: {
                    pollingTask?.cancel()
                    onSkip()
                }
            )
        }
        .padding(.horizontal, 48)
        .onAppear {
            initialCount = transcriptStore.recent(limit: 10_000).count
            startPolling()
        }
        .onDisappear { pollingTask?.cancel() }
    }

    private func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    let newCount = transcriptStore.recent(limit: 10_000).count
                    if newCount > initialCount {
                        succeeded = true
                        pollingTask?.cancel()
                    }
                }
            }
        }
    }
}

// MARK: - Step 6: Done

private struct DoneStep: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(SoroTheme.accent)

                Text("You're all set!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Hold Left Option anywhere to start dictating.\nSoro lives in your menu bar.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Button(action: onFinish) {
                Text("Start Using Soro")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(SoroTheme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 48)
    }
}

// MARK: - Shared sub-components

private struct OnboardingStepHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(SoroTheme.accent)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingStatusBadge: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(.white.opacity(0.85))
                .font(.callout)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OnboardingNavRow: View {
    let primaryLabel: String
    let primaryAction: () -> Void
    let skipLabel: String
    let skipAction: () -> Void
    var primaryDisabled: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: skipAction) {
                Text(skipLabel)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: primaryAction) {
                Text(primaryLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        primaryDisabled
                            ? Color.white.opacity(0.15)
                            : SoroTheme.accent,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
        }
    }
}

private struct CodeSnippet: View {
    let code: String
    init(_ code: String) { self.code = code }

    var body: some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }
}
