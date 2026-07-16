import SwiftUI

/// The Dynamic-Island recording bar content (brief §4a). Unlike a floating pill,
/// this HUGS the notch: a near-black body with a square top edge (flush to the
/// screen top) and rounded bottom corners, split into a LEFT zone and a RIGHT
/// zone separated by a center GAP the width of the physical notch — so the notch
/// sits in the middle and the UI wraps around it (iOS Dynamic Island / Willow).
///
/// Left zone: the frontmost-app icon captured at record start (+ lock glyph).
/// Right zone: the live waveform + elapsed timer + an X cancel button.
///
/// Post-recording status ("Transcribing"/"Failed"/"Pasted") is owned by the
/// top-right toast, so this bar only ever shows `.dormant` or `.recording`; every
/// other phase resolves to `.hidden` and the island retreats.
///
/// Contract: constructed as `RecordingBarView(coordinator:)`. The level stream,
/// cancel action, and notch geometry default sensibly but the hosting panel
/// injects the live values.
struct RecordingBarView: View {
    @ObservedObject var coordinator: DictationCoordinator
    /// Supplies the frontmost-app icon captured at record start (left slot).
    @ObservedObject var leftIcon: LeftIconProvider

    /// Live 0…1 mic levels (~30 Hz).
    let levelStream: AsyncStream<Float>
    /// Called by the X button. Defaults to cancelling the coordinator.
    let onCancel: () -> Void
    /// Render-phase inputs from preferences.
    var notchEnabled: Bool
    var hideBar: Bool
    var hideBarWhenIdle: Bool
    /// Width of the center gap the physical notch occupies (0 on non-notched Macs).
    var notchGap: CGFloat
    /// Width of each flanking content zone.
    var sideZone: CGFloat

    init(coordinator: DictationCoordinator,
         leftIcon: LeftIconProvider? = nil,
         levelStream: AsyncStream<Float>? = nil,
         notchEnabled: Bool = true,
         hideBar: Bool = false,
         hideBarWhenIdle: Bool = true,
         notchGap: CGFloat = RecordingBarModel.fallbackNotchWidth,
         sideZone: CGFloat = RecordingBarModel.sideZoneWidth,
         onCancel: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.leftIcon = leftIcon ?? LeftIconProvider()
        self.levelStream = levelStream ?? AsyncStream { $0.finish() }
        self.notchEnabled = notchEnabled
        self.hideBar = hideBar
        self.hideBarWhenIdle = hideBarWhenIdle
        self.notchGap = notchGap
        self.sideZone = sideZone
        self.onCancel = onCancel ?? { coordinator.cancelRecording() }
    }

    // Rolling waveform history + timing.
    @State private var levels: [CGFloat] = []
    @State private var elapsed: TimeInterval = 0
    @State private var recordStart: Date?

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var phase: RecordingBarModel.Phase {
        RecordingBarModel.phase(for: coordinator.state,
                                notchEnabled: notchEnabled,
                                hideBar: hideBar,
                                hideBarWhenIdle: hideBarWhenIdle)
    }

    private var pillWidth: CGFloat {
        RecordingBarModel.pillWidth(notchGap: notchGap, sideZone: sideZone)
    }

    var body: some View {
        // The pill fills the whole panel; it's pinned to the top so its square top
        // edge merges with the physical notch.
        VStack(spacing: 0) {
            content
                .frame(width: pillWidth, height: RecordingBarModel.pillHeight)
                .background(islandBackground)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .frame(width: pillWidth, height: RecordingBarModel.pillHeight, alignment: .top)
        .scaleEffect(RecordingBarModel.isVisible(phase) ? 1 : 0.92, anchor: .top)
        .opacity(RecordingBarModel.isVisible(phase) ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: phase)
        .task(id: streamRestartKey) { await consumeLevels() }
        .onReceive(timer) { _ in tick() }
        .onChange(of: coordinator.state) { _, _ in stateChanged() }
        .onAppear { stateChanged() }
    }

    // MARK: Content per phase (flanking the notch)

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .recording(let locked):
            flankedRow { leftZone(locked: locked) } right: { rightZone }
        case .dormant:
            flankedRow { dormantLeft } right: { dormantRight }
        case .hidden, .transcribing, .doneFlash:
            // Unreachable via `phase(for:)` (transcribing/done map to hidden); the
            // toast owns that status. Keep a near-zero footprint for clean anims.
            Color.clear
        }
    }

    /// Lays out a left zone and a right zone with a fixed center gap equal to the
    /// notch width, so the physical notch nests between them.
    private func flankedRow<L: View, R: View>(@ViewBuilder left: () -> L,
                                              @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 0) {
            left()
                .frame(width: sideZone, height: RecordingBarModel.pillHeight)
            // The notch lives here — an empty transparent gap.
            Color.clear.frame(width: notchGap, height: RecordingBarModel.pillHeight)
            right()
                .frame(width: sideZone, height: RecordingBarModel.pillHeight)
        }
    }

    // MARK: Recording zones

    private func leftZone(locked: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            LeftIconView(icon: leftIcon.icon)
                .animation(.spring(response: 0.3, dampingFraction: 0.7),
                           value: leftIcon.icon != nil)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // Pull content toward the notch (right edge of the left zone) and clear the
        // notch's rounded corner a touch.
        .padding(.trailing, 12)
        .padding(.leading, 10)
    }

    private var rightZone: some View {
        HStack(spacing: 8) {
            WaveformView(levels: levels, barCount: 22)
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            Text(RecordingBarModel.elapsedLabel(elapsed))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
    }

    // MARK: Dormant zones (click-to-start pill)

    private var dormantLeft: some View {
        HStack {
            Spacer(minLength: 0)
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.trailing, 12)
    }

    private var dormantRight: some View {
        HStack {
            Text("Soro")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
    }

    // MARK: Island background (square top, rounded bottom, near-solid black)

    private var islandBackground: some View {
        NotchShape()
            .fill(.black.opacity(0.94))
            .overlay(
                NotchShape()
                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 7, y: 3)
    }

    // MARK: Timing + level consumption

    private var streamRestartKey: Bool { RecordingBarModel.isRecordingPhase(phase) }

    private func consumeLevels() async {
        guard RecordingBarModel.isRecordingPhase(phase) else { return }
        for await level in levelStream {
            if Task.isCancelled { break }
            let frac = RecordingBarModel.barHeightFraction(forLevel: level)
            levels.append(frac)
            if levels.count > 64 { levels.removeFirst(levels.count - 64) }
        }
    }

    private func tick() {
        guard case .recording = coordinator.state else { return }
        if let start = recordStart {
            elapsed = Date().timeIntervalSince(start)
        }
    }

    private func stateChanged() {
        switch coordinator.state {
        case .recording:
            if recordStart == nil {
                recordStart = Date()
                elapsed = 0
                levels.removeAll()
            }
        case .idle:
            recordStart = nil
            elapsed = 0
            levels.removeAll()
        default:
            break
        }
    }
}
