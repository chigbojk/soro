import SwiftUI

/// One row in the History list (brief §4b).
/// Time on the left in muted caption, transcript text on the right, with a subtle
/// hover affordance and context-menu actions.
struct HistoryRowView: View {
    let transcript: Transcript
    let onCopy: (Transcript) -> Void
    let onDelete: (Transcript) -> Void
    let onReinsert: (Transcript) -> Void     // wired to a closure, may be no-op until M3 ships
    let onPlayAudio: (Transcript) -> Void    // wired to a closure, disabled placeholder

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(timeString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(SoroTheme.textTertiary)
                .frame(width: 58, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(isError ? SoroTheme.textSecondary : SoroTheme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if transcript.recordingDuration > 0 {
                    Text(durationString)
                        .font(.system(size: 11))
                        .foregroundStyle(SoroTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovered && !isError {
                Button {
                    onCopy(transcript)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SoroTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Copy")
                .padding(.top, 1)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? SoroTheme.accentTint : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) { hovered = h }
        }
        .contextMenu {
            Button {
                onCopy(transcript)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                onReinsert(transcript)
            } label: {
                Label("Re-insert", systemImage: "arrow.uturn.left")
            }
            // Re-insert is a placeholder until InsertionService (M3) is available.
            // The closure is wired so AppState/DashboardWindow can enable it later.

            Divider()

            Button {
                onPlayAudio(transcript)
            } label: {
                Label("Play Audio", systemImage: "play.circle")
            }
            .disabled(transcript.audioURL == nil)
            // Disabled placeholder: audio playback will be enabled in a later milestone.

            Divider()

            Button(role: .destructive) {
                onDelete(transcript)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private var isError: Bool {
        transcript.text == Transcript.errorSentinel
    }

    private var displayText: String {
        isError ? "Transcription failed" : transcript.text
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: transcript.timestamp)
    }

    private var durationString: String {
        let d = transcript.recordingDuration
        if d < 60 {
            return String(format: "%.0fs", d)
        } else {
            return String(format: "%dm %.0fs", Int(d) / 60, d.truncatingRemainder(dividingBy: 60))
        }
    }
}
