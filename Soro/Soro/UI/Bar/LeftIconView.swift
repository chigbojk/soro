import SwiftUI

/// The pill's left slot: the frontmost app's icon captured at record start, or a
/// mic SF Symbol fallback (brief §4a redesign). Sized ~18–20pt to visually flank
/// the notch's left side.
struct LeftIconView: View {
    /// Captured app icon; nil drives the mic fallback.
    let icon: NSImage?
    var size: CGFloat = 19

    private var kind: RecordingBarModel.LeftIcon {
        RecordingBarModel.leftIcon(hasCapturedIcon: icon != nil)
    }

    var body: some View {
        Group {
            switch kind {
            case .appIcon:
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22,
                                                    style: .continuous))
                }
            case .micFallback:
                Image(systemName: "mic.fill")
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: size, height: size)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 20) {
        LeftIconView(icon: nil)
        LeftIconView(icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil))
    }
    .padding()
    .background(.black)
}
#endif
