import SwiftUI

/// A row of `barCount` vertical bars that animate from live mic level samples
/// (brief §4a). Fed by a rolling window of recent levels so the wave appears to
/// scroll left as new samples arrive on the right.
struct WaveformView: View {
    /// Rolling history of normalized bar-height fractions (0…1), oldest first.
    /// The view renders the last `barCount` entries.
    let levels: [CGFloat]
    var barCount: Int = 24
    var spacing: CGFloat = 2
    var minBarHeight: CGFloat = 3
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let count = max(barCount, 1)
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = max((geo.size.width - totalSpacing) / CGFloat(count), 1)
            let window = windowed(count: count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(window.indices, id: \.self) { i in
                    let frac = window[i]
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.55 + 0.45 * Double(frac)))
                        .frame(width: barWidth,
                               height: max(minBarHeight, frac * geo.size.height))
                        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: frac)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    /// Right-aligns the history into a fixed-width window, left-padding with the
    /// noise floor when there aren't enough samples yet.
    private func windowed(count: Int) -> [CGFloat] {
        if levels.count >= count {
            return Array(levels.suffix(count))
        }
        return Array(repeating: 0.06, count: count - levels.count) + levels
    }
}

#if DEBUG
#Preview {
    WaveformView(levels: (0..<24).map { _ in CGFloat.random(in: 0.1...1) })
        .frame(width: 160, height: 24)
        .padding()
        .background(.black)
}
#endif
