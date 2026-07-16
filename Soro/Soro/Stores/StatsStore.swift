import Foundation
import Combine

/// JSON-backed store for `Preferences/feature_usage_stats.json`.
///
/// Holds the raw lifetime counters and derives the Home-screen figures
/// (dictated words, avg WPM, time saved, day streak) from transcripts.
///
/// The `stats-recap` feature adds "Wrapped"-style aggregation on top: per-app paste
/// counts, per-month rollups, a most-transcribed-words tally, and longest-streak
/// tracking — all persisted (back-compatibly) in the same JSON file and surfaced via
/// `computeRecap(month:)`.
@MainActor
final class StatsStore: ObservableObject {
    @Published var stats: UsageStats

    /// Running totals used to derive words/WPM. Not persisted in Willow's schema,
    /// kept in-memory and re-derivable from transcripts (brief §6).
    @Published private(set) var totalWords: Int = 0
    @Published private(set) var totalDuration: TimeInterval = 0

    private let paths: AppPaths

    init(paths: AppPaths = .live) {
        self.paths = paths
        self.stats = JSONFile.read(UsageStats.self, from: paths.statsFile) ?? .default
    }

    func save() {
        try? JSONFile.write(stats, to: paths.statsFile)
    }

    /// Records one completed dictation (legacy signature — words + duration only).
    ///
    /// Retained for source compatibility. Prefer the richer overload below so the
    /// recap can attribute the dictation to an app and mine its words.
    func recordDictation(words: Int, duration: TimeInterval) {
        recordDictation(words: words, duration: duration, appName: "", bundleId: "", text: nil)
    }

    /// Records one completed dictation with per-app + text attribution for the recap.
    ///
    /// - Parameters:
    ///   - words: word count of the final inserted text.
    ///   - duration: recording duration in seconds.
    ///   - appName: display name of the target app (may be empty).
    ///   - bundleId: bundle id of the target app (may be empty; skipped if so).
    ///   - text: the final text, mined for top-words. Pass `nil` to skip word mining.
    ///   - now: injectable clock for tests.
    func recordDictation(words: Int,
                         duration: TimeInterval,
                         appName: String,
                         bundleId: String,
                         text: String?,
                         now: Date = Date()) {
        stats.lifetimeDictations += 1
        totalWords += words
        totalDuration += duration

        // Per-app tally.
        let trimmedBundle = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBundle.isEmpty {
            var entry = stats.appUsage[trimmedBundle] ?? AppUsageStat(appName: appName)
            entry.count += 1
            entry.words += words
            // Keep the freshest non-empty name.
            if !appName.isEmpty { entry.appName = appName }
            stats.appUsage[trimmedBundle] = entry
        }

        // Per-month rollup.
        let key = UsageStats.monthKey(for: now)
        var month = stats.monthly[key] ?? MonthlyStat()
        month.dictations += 1
        month.words += words
        month.duration += duration
        stats.monthly[key] = month

        // Top-words mining.
        if let text {
            for token in Self.tokenize(text) {
                stats.wordCounts[token, default: 0] += 1
            }
        }

        save()
    }

    func markHandsFreeUsed() {
        guard !stats.handsFreeEverUsed else { return }
        stats.handsFreeEverUsed = true
        save()
    }

    func markBarMoved() {
        guard !stats.barEverMoved else { return }
        stats.barEverMoved = true
        save()
    }

    // MARK: Derived Home stats

    /// Total dictated words across the lifetime.
    var dictatedWords: Int { totalWords }

    /// Average speaking speed in words-per-minute.
    var avgWPM: Int {
        guard totalDuration > 0 else { return 0 }
        return Int((Double(totalWords) / totalDuration) * 60.0)
    }

    /// Rough "time saved" heuristic: dictation vs. typing at ~40 wpm.
    var timeSavedSeconds: TimeInterval {
        Self.timeSaved(words: totalWords, spokenSeconds: totalDuration)
    }

    /// Consecutive-day usage streak. Derived from transcripts by the caller;
    /// stored here so the Home view can bind to it. Defaults to 0.
    @Published var dayStreak: Int = 0

    /// Recomputes `totalWords`, `totalDuration`, and `dayStreak` from a set of
    /// transcripts (called once by AppState after stores are built). Also refreshes the
    /// persisted `longestStreak` high-water mark.
    func recompute(from transcripts: [Transcript]) {
        totalWords = transcripts.reduce(0) { $0 + wordCount($1.text) }
        totalDuration = transcripts.reduce(0) { $0 + $1.recordingDuration }
        dayStreak = Self.computeStreak(from: transcripts)

        let longest = Self.computeLongestStreak(from: transcripts)
        if longest > stats.longestStreak {
            stats.longestStreak = longest
            save()
        } else if dayStreak > stats.longestStreak {
            stats.longestStreak = dayStreak
            save()
        }
    }

    private func wordCount(_ text: String) -> Int {
        guard text != Transcript.errorSentinel else { return 0 }
        return text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    // MARK: - Recap computation

    /// Builds a presentation-ready recap for a month (defaults to the current month).
    ///
    /// - Parameters:
    ///   - month: `"yyyy-MM"` key; defaults to the current month.
    ///   - topN: cap for both top-apps and top-words.
    ///   - now: injectable clock for the current-streak figure.
    func computeRecap(month: String = UsageStats.monthKey(for: Date()),
                      topN: Int = 5,
                      now: Date = Date()) -> RecapSummary {
        let m = stats.monthly[month] ?? MonthlyStat()

        let topApps: [RecapSummary.TopApp] = stats.appUsage
            .map { RecapSummary.TopApp(bundleId: $0.key, appName: $0.value.appName, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.bundleId < rhs.bundleId          // stable tie-break
            }
            .prefix(topN)
            .map { $0 }

        let topWords: [RecapSummary.TopWord] = stats.wordCounts
            .map { RecapSummary.TopWord(word: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.word < rhs.word                   // stable tie-break
            }
            .prefix(topN)
            .map { $0 }

        return RecapSummary(
            monthKey: month,
            monthLabel: Self.monthLabel(for: month),
            words: m.words,
            dictations: m.dictations,
            timeSavedSeconds: Self.timeSaved(words: m.words, spokenSeconds: m.duration),
            topApps: topApps,
            topWords: topWords,
            currentStreak: dayStreak,
            longestStreak: max(stats.longestStreak, dayStreak)
        )
    }

    // MARK: - Pure helpers (unit-testable)

    /// Typing-time-saved heuristic: assume typing at ~40 wpm; saved = typing − spoken.
    static func timeSaved(words: Int, spokenSeconds: TimeInterval) -> TimeInterval {
        let typingSeconds = (Double(words) / 40.0) * 60.0
        return max(0, typingSeconds - spokenSeconds)
    }

    /// Current consecutive-day streak ending today or yesterday.
    static func computeStreak(from transcripts: [Transcript], now: Date = Date()) -> Int {
        let cal = Calendar.current
        let days = Set(transcripts.map { cal.startOfDay(for: $0.timestamp) })
        guard !days.isEmpty else { return 0 }

        var streak = 0
        var day = cal.startOfDay(for: now)
        // Allow the streak to start today or yesterday.
        if !days.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day),
                  days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        while days.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// The longest run of consecutive active days anywhere in the history.
    static func computeLongestStreak(from transcripts: [Transcript]) -> Int {
        let cal = Calendar.current
        let days = Set(transcripts.map { cal.startOfDay(for: $0.timestamp) })
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()

        var longest = 1
        var run = 1
        for i in 1..<sorted.count {
            if let next = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]),
               next == sorted[i] {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }
        return longest
    }

    /// Friendly label for a `"yyyy-MM"` key, e.g. "July 2026". Falls back to the key.
    static func monthLabel(for monthKey: String) -> String {
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else { return monthKey }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return monthKey }
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        return fmt.string(from: date)
    }

    // MARK: - Tokenizer / stopwords (local; independent of AutoDictionaryStore)

    /// A tiny English stopword set used purely for the recap's "top words" tally.
    /// Duplicated locally on purpose so the recap does not depend on AutoDictionaryStore.
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "so", "because",
        "of", "to", "in", "on", "at", "for", "with", "by", "from", "as", "into",
        "is", "am", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "doing", "have", "has", "had", "having",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "mine", "yours", "ours", "theirs",
        "this", "that", "these", "those", "here", "there",
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "not", "no", "nor", "can", "cannot", "could", "will", "would", "shall",
        "should", "may", "might", "must", "just", "than", "too", "very",
        "up", "down", "out", "off", "over", "under", "again", "once",
        "about", "against", "between", "through", "during", "before", "after",
        "all", "any", "both", "each", "few", "more", "most", "other", "some", "such",
        "only", "own", "same", "get", "got", "like", "want", "know", "going", "yeah",
        "okay", "ok", "um", "uh", "gonna", "wanna", "let", "well", "really", "much"
    ]

    /// Lowercases, strips punctuation, drops stopwords / very short tokens / pure
    /// numbers, and returns the remaining significant words.
    static func tokenize(_ text: String) -> [String] {
        guard text != Transcript.errorSentinel else { return [] }
        let lowered = text.lowercased()
        // Split on anything that isn't a letter or number.
        let rawTokens = lowered.split { !($0.isLetter || $0.isNumber) }
        var out: [String] = []
        out.reserveCapacity(rawTokens.count)
        for token in rawTokens {
            let word = String(token)
            guard word.count >= 3 else { continue }
            guard !stopwords.contains(word) else { continue }
            // Skip pure numbers.
            if word.allSatisfy({ $0.isNumber }) { continue }
            out.append(word)
        }
        return out
    }
}
