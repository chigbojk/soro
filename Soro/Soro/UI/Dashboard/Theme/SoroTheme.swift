import SwiftUI
import AppKit

/// Shared visual design tokens for the dashboard (brief §4b: light theme, purple accent).
///
/// Willow-grade look: soft cream/white canvas, elevated rounded cards, a single
/// purple accent, generous spacing, and a clear text hierarchy. All dashboard
/// screens draw from these tokens so the app feels cohesive and premium.
///
/// This type replaces the earlier one-property placeholder; existing call sites that
/// used `SoroTheme.accent` keep working unchanged.
enum SoroTheme {

    // MARK: - Colors

    /// Primary purple accent (~#5B4FE6). Used for interactive tint, icons, highlights.
    static let accent = Color(red: 0x5B / 255, green: 0x4F / 255, blue: 0xE6 / 255)

    /// A softer secondary accent used for gradient tails and subtle fills.
    static let accentSoft = Color(red: 0x7C / 255, green: 0x73 / 255, blue: 0xF0 / 255)

    /// App canvas background — warm off-white / cream, lighter than the cards sit on.
    static let canvas = Color(red: 0xFA / 255, green: 0xF9 / 255, blue: 0xFC / 255)

    /// Card surface — pure white so cards read as elevated above the cream canvas.
    static let card = Color.white

    /// A very light lilac tint used behind icons and accent chips.
    static let accentTint = Color(red: 0x5B / 255, green: 0x4F / 255, blue: 0xE6 / 255).opacity(0.10)

    /// Hairline border color for cards and controls.
    static let hairline = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x2E / 255).opacity(0.08)

    // Text tiers
    static let textPrimary = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x2E / 255)
    static let textSecondary = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x2E / 255).opacity(0.62)
    static let textTertiary = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x2E / 255).opacity(0.40)

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Standard screen edge inset.
        static let screen: CGFloat = 28
    }

    // MARK: - Corner radii

    enum Radius {
        static let chip: CGFloat = 20
        static let control: CGFloat = 10
        static let card: CGFloat = 16
        static let large: CGFloat = 20
    }

    // MARK: - Gradients

    /// Subtle diagonal accent gradient for hero surfaces and icon tiles.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSoft],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Card modifier

/// The shared card container: white surface, 16pt radius, hairline border, soft shadow.
struct SoroCard: ViewModifier {
    var padding: CGFloat = SoroTheme.Spacing.lg
    var cornerRadius: CGFloat = SoroTheme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(SoroTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SoroTheme.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}

extension View {
    /// Wraps the view in the shared Soro card surface.
    func soroCard(
        padding: CGFloat = SoroTheme.Spacing.lg,
        cornerRadius: CGFloat = SoroTheme.Radius.card
    ) -> some View {
        modifier(SoroCard(padding: padding, cornerRadius: cornerRadius))
    }
}

// MARK: - Accent icon tile

/// A small rounded, tinted tile hosting an SF Symbol — the accent motif used in
/// card headers, stat cards, and suggestion rows.
struct AccentIconTile: View {
    let systemImage: String
    var size: CGFloat = 30
    var symbolSize: CGFloat = 14
    /// When true the tile uses the full accent gradient with a white glyph.
    var filled: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(filled ? AnyShapeStyle(SoroTheme.accentGradient)
                             : AnyShapeStyle(SoroTheme.accentTint))
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(filled ? Color.white : SoroTheme.accent)
        }
    }
}

// MARK: - Section header

/// A consistent screen title + subtitle block used at the top of each screen.
struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(SoroTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(SoroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Keycap pill

/// A macOS-style keycap used in the Home header (e.g. `⌥ Opt`).
struct KeycapPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(SoroTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SoroTheme.hairline, lineWidth: 1)
            )
    }
}
