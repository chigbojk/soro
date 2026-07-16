import SwiftUI

/// A single stat card for the Home screen (brief §4b).
///
/// Willow-grade card: soft-shadowed white surface, 16pt radius, a tinted SF Symbol
/// tile, a large rounded value with an optional unit, and a muted label — a clear
/// value → unit → label hierarchy.
struct StatCardView: View {
    let title: String
    /// The primary numeric value, already formatted (e.g. "1,204").
    let value: String
    /// An optional trailing unit shown smaller next to the value (e.g. "wpm", "min").
    var unit: String? = nil
    let systemImage: String
    /// Per-stat tint so the row of cards reads as a colorful set while staying cohesive.
    var tint: Color = SoroTheme.accent

    var body: some View {
        // Willow layout: small grey label on top, big value below with a small
        // grey unit beside it. No icon — clean and minimal.
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SoroTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(SoroTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SoroTheme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .soroCard(padding: 18)
    }
}
