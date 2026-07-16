import Foundation
import UserNotifications

/// Posts a once-per-calendar-month local notification summarizing the previous month's
/// dictation activity ("Wrapped"-style recap).
///
/// Design notes:
///   - Fires at most once per calendar month, guarded by `UsageStats.lastRecapMonthKey`.
///   - Recaps the *previous* completed month (so the numbers are final), not the running
///     current month.
///   - Requests notification authorization lazily and degrades gracefully: if
///     notifications are unavailable / denied, or if UNUserNotificationCenter can't be
///     obtained (e.g. an unbundled test host), it simply no-ops. It never throws to the
///     caller and never blocks the main actor on a hang.
@MainActor
final class RecapNotifier {
    private let stats: StatsStore

    /// Abstracts the notification center so tests don't touch the real one (which
    /// requires a bundled app). Production uses `.current()` when available.
    private let center: UNUserNotificationCenter?

    init(stats: StatsStore, center: UNUserNotificationCenter? = RecapNotifier.defaultCenter()) {
        self.stats = stats
        self.center = center
    }

    /// Returns the shared center, or `nil` when running outside a proper app bundle
    /// (calling `.current()` there traps), so the notifier can no-op safely.
    nonisolated static func defaultCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Checks whether a new month's recap is due and, if so, posts it. Safe to call on
    /// every launch — it self-guards via `lastRecapMonthKey`.
    ///
    /// - Parameter now: injectable clock for tests.
    func checkAndNotify(now: Date = Date()) {
        // Recap the *previous* month so figures are complete.
        let cal = Calendar.current
        guard let lastMonthDate = cal.date(byAdding: .month, value: -1, to: now) else { return }
        let targetKey = UsageStats.monthKey(for: lastMonthDate)

        // Already shown for this month? Nothing to do.
        guard stats.stats.lastRecapMonthKey != targetKey else { return }

        let recap = stats.computeRecap(month: targetKey, now: now)

        // Mark as shown regardless of whether there's content, so an empty month doesn't
        // keep re-triggering the check every launch.
        stats.stats.lastRecapMonthKey = targetKey
        stats.save()

        // Nothing meaningful happened — skip the notification but keep the guard set.
        guard !recap.isEmpty else { return }

        post(recap)
    }

    /// Requests authorization (lazily) and posts the recap notification. No-ops if the
    /// center is unavailable or authorization is denied.
    private func post(_ recap: RecapSummary) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your \(recap.monthLabel) recap"
            content.body = Self.body(for: recap)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "recap-\(recap.monthKey)",
                content: content,
                trigger: nil)   // deliver immediately
            center.add(request, withCompletionHandler: nil)
        }
    }

    /// Builds the one-line notification body, e.g.
    /// "You dictated 4,210 words in 132 dictations and saved 41 min. Streak: 6 days."
    static func body(for recap: RecapSummary) -> String {
        let words = numberString(recap.words)
        let dictations = numberString(recap.dictations)
        var text = "You dictated \(words) words in \(dictations) dictations"
        let saved = timeString(recap.timeSavedSeconds)
        if !saved.isEmpty {
            text += " and saved \(saved)"
        }
        text += "."
        if recap.currentStreak > 0 {
            text += " Streak: \(recap.currentStreak) day\(recap.currentStreak == 1 ? "" : "s")."
        }
        return text
    }

    private static func numberString(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "" }
        if seconds < 3600 {
            return "\(Int(seconds / 60)) min"
        }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
}
