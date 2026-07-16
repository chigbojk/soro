import SwiftUI
import AppKit

/// A "Wrapped"-style monthly recap highlight for the Home screen.
///
/// Willow-grade visuals: an accent-gradient hero header, three headline figures
/// (words · dictations · time saved), streak chips, top apps rendered with their real
/// app icons (resolved via `NSWorkspace` by bundle id), and a top-words chip cloud.
/// Dismissible for the current month via a passed-in binding.
struct RecapCard: View {
    let recap: RecapSummary
    /// Called when the user taps the dismiss (×) control.
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: SoroTheme.Spacing.lg) {
            header
            headlineFigures
            if !recap.topApps.isEmpty { topAppsRow }
            if !recap.topWords.isEmpty { topWordsRow }
            streakRow
        }
        .padding(SoroTheme.Spacing.xl)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: SoroTheme.Radius.large, style: .continuous)
                .strokeBorder(SoroTheme.hairline, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, x: 0, y: 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            AccentIconTile(systemImage: "sparkles", size: 34, symbolSize: 16, filled: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("This month")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SoroTheme.accent)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(recap.monthLabel)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SoroTheme.textPrimary)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SoroTheme.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(SoroTheme.card))
                    .overlay(Circle().strokeBorder(SoroTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Dismiss this month's recap")
        }
    }

    // MARK: - Headline figures

    private var headlineFigures: some View {
        HStack(spacing: SoroTheme.Spacing.md) {
            figure(value: formattedNumber(recap.words), label: "words")
            figureDivider
            figure(value: formattedNumber(recap.dictations), label: "dictations")
            figureDivider
            figure(value: timeSaved, label: "saved")
        }
    }

    private func figure(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(SoroTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SoroTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var figureDivider: some View {
        Rectangle()
            .fill(SoroTheme.hairline)
            .frame(width: 1, height: 34)
    }

    // MARK: - Top apps

    private var topAppsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Top apps")
            HStack(spacing: 10) {
                ForEach(recap.topApps) { app in
                    HStack(spacing: 7) {
                        appIcon(for: app.bundleId)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(displayName(for: app))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(SoroTheme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous).fill(SoroTheme.canvas)
                    )
                    .overlay(
                        Capsule(style: .continuous).strokeBorder(SoroTheme.hairline, lineWidth: 1)
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func appIcon(for bundleId: String) -> some View {
        if let icon = Self.icon(forBundleId: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(SoroTheme.accentTint)
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SoroTheme.accent)
                )
        }
    }

    /// Resolves an app icon by bundle id via NSWorkspace. Returns nil if the app isn't
    /// installed / can't be located.
    static func icon(forBundleId bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func displayName(for app: RecapSummary.TopApp) -> String {
        if !app.appName.isEmpty { return app.appName }
        // Fall back to the last path component of the bundle id.
        return app.bundleId.split(separator: ".").last.map(String.init) ?? app.bundleId
    }

    // MARK: - Top words

    private var topWordsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Most-said words")
            // Reuses the shared FlowLayout (also used by DictionaryView) for a wrapping
            // chip cloud.
            FlowLayout(spacing: 8) {
                ForEach(recap.topWords) { entry in
                    Text(entry.word)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SoroTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(SoroTheme.accentTint))
                }
            }
        }
    }

    // MARK: - Streaks

    private var streakRow: some View {
        HStack(spacing: 10) {
            streakChip(
                icon: "flame.fill",
                tint: Color(red: 0xF0 / 255, green: 0x7B / 255, blue: 0x3F / 255),
                value: "\(recap.currentStreak)",
                label: recap.currentStreak == 1 ? "day streak" : "day streak")
            streakChip(
                icon: "trophy.fill",
                tint: Color(red: 0xE0 / 255, green: 0xA9 / 255, blue: 0x2E / 255),
                value: "\(recap.longestStreak)",
                label: "longest streak")
            Spacer(minLength: 0)
        }
    }

    private func streakChip(icon: String, tint: Color, value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SoroTheme.textPrimary)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SoroTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SoroTheme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SoroTheme.hairline, lineWidth: 1))
    }

    // MARK: - Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(SoroTheme.textTertiary)
            .tracking(0.5)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: SoroTheme.Radius.large, style: .continuous)
            .fill(SoroTheme.card)
            .overlay(
                // A soft accent wash in the top-trailing corner for the "hero" feel.
                RoundedRectangle(cornerRadius: SoroTheme.Radius.large, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [SoroTheme.accent.opacity(0.10), SoroTheme.accent.opacity(0.0)],
                            startPoint: .topTrailing,
                            endPoint: .center)
                    )
            )
    }

    private func formattedNumber(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private var timeSaved: String {
        let seconds = recap.timeSavedSeconds
        guard seconds >= 60 else { return "0m" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}
