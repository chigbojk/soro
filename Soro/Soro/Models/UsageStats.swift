import Foundation

/// Lifetime usage counters, mirroring `Preferences/feature_usage_stats.json` (brief §6).
///
/// The original four lifetime flags are unchanged. The `stats-recap` feature layers on
/// richer, "Wrapped"-style aggregates: per-app paste counts, per-month rollups, a
/// most-transcribed-words tally, and streak tracking. Every new field is optional or
/// defaulted so existing `feature_usage_stats.json` files decode unchanged (JSON
/// back-compat), and unknown-to-old-code keys are simply ignored by the old decoder.
struct UsageStats: Codable, Equatable {
    var lifetimeDictations: Int
    var lifetimeScribeUses: Int
    var handsFreeEverUsed: Bool
    var barEverMoved: Bool

    // MARK: - Recap aggregates (all optional/defaulted for JSON back-compat)

    /// Paste counts keyed by app bundle id. Value carries a display name + count so the
    /// recap can render an icon (via bundle id) and a label without a second lookup.
    var appUsage: [String: AppUsageStat]

    /// Per-calendar-month rollups keyed by `"yyyy-MM"` (see `UsageStats.monthKey`).
    var monthly: [String: MonthlyStat]

    /// Most-transcribed words across the lifetime (lowercased, stopword-filtered).
    var wordCounts: [String: Int]

    /// Longest consecutive-day streak ever achieved. Kept as a high-water mark so it
    /// survives even after the current streak resets.
    var longestStreak: Int

    /// The last calendar month (`"yyyy-MM"`) for which the monthly recap notification
    /// was posted. Guards the once-per-month notifier. `nil` = never shown.
    var lastRecapMonthKey: String?

    static let `default` = UsageStats(
        lifetimeDictations: 0,
        lifetimeScribeUses: 0,
        handsFreeEverUsed: false,
        barEverMoved: false,
        appUsage: [:],
        monthly: [:],
        wordCounts: [:],
        longestStreak: 0,
        lastRecapMonthKey: nil
    )

    private enum CodingKeys: String, CodingKey {
        case lifetimeDictations, lifetimeScribeUses, handsFreeEverUsed, barEverMoved
        case appUsage, monthly, wordCounts, longestStreak, lastRecapMonthKey
    }

    init(lifetimeDictations: Int,
         lifetimeScribeUses: Int,
         handsFreeEverUsed: Bool,
         barEverMoved: Bool,
         appUsage: [String: AppUsageStat] = [:],
         monthly: [String: MonthlyStat] = [:],
         wordCounts: [String: Int] = [:],
         longestStreak: Int = 0,
         lastRecapMonthKey: String? = nil) {
        self.lifetimeDictations = lifetimeDictations
        self.lifetimeScribeUses = lifetimeScribeUses
        self.handsFreeEverUsed = handsFreeEverUsed
        self.barEverMoved = barEverMoved
        self.appUsage = appUsage
        self.monthly = monthly
        self.wordCounts = wordCounts
        self.longestStreak = longestStreak
        self.lastRecapMonthKey = lastRecapMonthKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lifetimeDictations = try c.decodeIfPresent(Int.self, forKey: .lifetimeDictations) ?? 0
        lifetimeScribeUses = try c.decodeIfPresent(Int.self, forKey: .lifetimeScribeUses) ?? 0
        handsFreeEverUsed = try c.decodeIfPresent(Bool.self, forKey: .handsFreeEverUsed) ?? false
        barEverMoved = try c.decodeIfPresent(Bool.self, forKey: .barEverMoved) ?? false
        appUsage = try c.decodeIfPresent([String: AppUsageStat].self, forKey: .appUsage) ?? [:]
        monthly = try c.decodeIfPresent([String: MonthlyStat].self, forKey: .monthly) ?? [:]
        wordCounts = try c.decodeIfPresent([String: Int].self, forKey: .wordCounts) ?? [:]
        longestStreak = try c.decodeIfPresent(Int.self, forKey: .longestStreak) ?? 0
        lastRecapMonthKey = try c.decodeIfPresent(String.self, forKey: .lastRecapMonthKey)
    }

    // MARK: - Month key helper

    /// Canonical `"yyyy-MM"` key for a date, in the current calendar/timezone. Uses a
    /// fixed POSIX locale so the key is stable regardless of user locale.
    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        return String(format: "%04d-%02d", y, m)
    }
}

/// Per-app paste tally used by the recap "top apps" section.
struct AppUsageStat: Codable, Equatable {
    /// Human-readable app name captured at record time (may be empty for unknown apps).
    var appName: String
    /// Number of dictations pasted into this app.
    var count: Int
    /// Total words dictated into this app.
    var words: Int

    init(appName: String, count: Int = 0, words: Int = 0) {
        self.appName = appName
        self.count = count
        self.words = words
    }
}

/// Per-calendar-month rollup used by the recap "this month" figures.
struct MonthlyStat: Codable, Equatable {
    var dictations: Int
    var words: Int
    /// Accumulated recording duration for the month, in seconds.
    var duration: TimeInterval

    init(dictations: Int = 0, words: Int = 0, duration: TimeInterval = 0) {
        self.dictations = dictations
        self.words = words
        self.duration = duration
    }
}

/// A computed, presentation-ready summary of a single month for the recap card /
/// notification. Pure value type — produced by `StatsStore.computeRecap(month:)`.
struct RecapSummary: Equatable {
    /// The `"yyyy-MM"` key this recap describes.
    let monthKey: String
    /// A friendly month label, e.g. "July 2026".
    let monthLabel: String
    let words: Int
    let dictations: Int
    /// Estimated typing time saved this month, in seconds.
    let timeSavedSeconds: TimeInterval
    /// Top apps by paste count (already sorted, capped to the requested N).
    let topApps: [TopApp]
    /// Top transcribed words (lifetime tally; sorted desc, capped to N).
    let topWords: [TopWord]
    /// Current live streak (as of "now").
    let currentStreak: Int
    /// Longest streak ever.
    let longestStreak: Int

    struct TopApp: Equatable, Identifiable {
        let bundleId: String
        let appName: String
        let count: Int
        var id: String { bundleId }
    }

    struct TopWord: Equatable, Identifiable {
        let word: String
        let count: Int
        var id: String { word }
    }

    /// True when there's essentially nothing to show (no dictations this month).
    var isEmpty: Bool { dictations == 0 && words == 0 }
}

/// One entry in `Preferences/auto_dictionary_cache.json` (brief §6/§3c).
struct AutoDictionaryEntry: Codable, Equatable {
    var word: String
    var firstSeen: Double             // Cocoa epoch
    var lastSeen: Double              // Cocoa epoch
    var occurrenceCount: Int
}
