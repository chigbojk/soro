import SwiftUI

/// A single toast card: dark translucent capsule with a leading icon, a short message,
/// and a draining countdown bar along the bottom (for auto-dismissible toasts). Sticky
/// toasts ("Transcribing…") show an indeterminate shimmer instead of a countdown.
///
/// Visual language mirrors the notch bar (brief §4a): dark, rounded, subtle shadow,
/// purple accent for progress.
struct ToastView: View {
    let toast: Toast
    /// Monotonic clock used to compute the countdown fraction. Injected so the panel and
    /// tests share one time base; defaults to process uptime.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private static let accent = Color(red: 0.31, green: 0.27, blue: 0.90)   // #4F46E5-ish

    private var tint: Color {
        switch toast.style {
        case .info:    return Self.accent
        case .success: return Color.green
        case .failure: return Color(red: 0.90, green: 0.30, blue: 0.30)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: toast.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(toast.message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)

            countdownBar
        }
        .frame(minWidth: 120, maxWidth: 300, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(toast.message))
    }

    @ViewBuilder
    private var countdownBar: some View {
        if toast.duration != nil {
            // Auto-dismissible → draining countdown. Re-evaluated ~30 Hz via TimelineView.
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                let fraction = toast.remainingFraction(at: now())
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.08))
                        Rectangle()
                            .fill(tint)
                            .frame(width: geo.size.width * CGFloat(fraction))
                    }
                }
                .frame(height: 2.5)
            }
        } else {
            // Sticky → indeterminate shimmer to signal ongoing work.
            ShimmerBar(tint: tint).frame(height: 2.5)
        }
    }
}

/// A small looping shimmer used under sticky toasts.
private struct ShimmerBar: View {
    let tint: Color
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Rectangle().fill(Color.white.opacity(0.06))
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, tint.opacity(0.9), .clear],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(40, w * 0.35))
                        .offset(x: phase * w)
                )
                .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

/// The vertical stack of toasts hosted inside `ToastPanel`. Top-anchored so newest
/// toasts push down; each animates in/out. Purely a presenter over `ToastCenter.toasts`.
struct ToastStackView: View {
    @ObservedObject var center: ToastCenter
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                ToastView(toast: toast, now: now)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.92))))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: center.toasts)
    }
}
