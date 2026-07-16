import XCTest
@testable import Soro

@MainActor
final class StatsRecapTests: XCTestCase {

    // MARK: - JSON back-compat

    func testDecodesLegacyStatsWithoutRecapFields() throws {
        // A pre-recap feature_usage_stats.json (only the original four keys).
        let legacy = """
        {
          "lifetimeDictations": 12,
          "lifetimeScribeUses": 3,
          "handsFreeEverUsed": true,
          "barEverMoved": false
        }
        """.data(using: .utf8)!

        let stats = try JSONDecoder().decode(UsageStats.self, from: legacy)
        XCTAssertEqual(stats.lifetimeDictations, 12)
        XCTAssertEqual(stats.lifetimeScribeUses, 3)
        XCTAssertTrue(stats.handsFreeEverUsed)
        XCTAssertFalse(stats.barEverMoved)
        // New fields default cleanly.
        XCTAssertTrue(stats.appUsage.isEmpty)
        XCTAssertTrue(stats.monthly.isEmpty)
        XCTAssertTrue(stats.wordCounts.isEmpty)
        XCTAssertEqual(stats.longestStreak, 0)
        XCTAssertNil(stats.lastRecapMonthKey)
    }

    func testRecapFieldsRoundTrip() throws {
        var stats = UsageStats.default
        stats.lifetimeDictations = 5
        stats.appUsage["com.apple.Safari"] = AppUsageStat(appName: "Safari", count: 4, words: 40)
        stats.monthly["2026-07"] = MonthlyStat(dictations: 4, words: 40, duration: 30)
        stats.wordCounts["swift"] = 7
        stats.longestStreak = 9
        stats.lastRecapMonthKey = "2026-06"

        let data = try JSONFile.encoder().encode(stats)
        let decoded = try JSONDecoder().decode(UsageStats.self, from: data)
        XCTAssertEqual(decoded, stats)
    }

    func testPersistedRoundTripThroughStore() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }

        let store = StatsStore(paths: paths)
        store.recordDictation(words: 5, duration: 3,
                              appName: "Notes", bundleId: "com.apple.Notes",
                              text: "remember to buy milk today")
        store.recordDictation(words: 3, duration: 2,
                              appName: "Notes", bundleId: "com.apple.Notes",
                              text: "milk milk milk")

        // Fresh store reads the same data back.
        let reloaded = StatsStore(paths: paths)
        XCTAssertEqual(reloaded.stats.lifetimeDictations, 2)
        XCTAssertEqual(reloaded.stats.appUsage["com.apple.Notes"]?.count, 2)
        XCTAssertEqual(reloaded.stats.appUsage["com.apple.Notes"]?.words, 8)
        XCTAssertEqual(reloaded.stats.wordCounts["milk"], 4) // 1 + 3
    }

    // MARK: - Aggregation math

    func testMonthlyRollupsUseRecordDate() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StatsStore(paths: paths)

        let july = date(2026, 7, 10)
        let august = date(2026, 8, 2)

        store.recordDictation(words: 10, duration: 5, appName: "A", bundleId: "a", text: nil, now: july)
        store.recordDictation(words: 20, duration: 6, appName: "A", bundleId: "a", text: nil, now: july)
        store.recordDictation(words: 4, duration: 2, appName: "A", bundleId: "a", text: nil, now: august)

        XCTAssertEqual(store.stats.monthly["2026-07"]?.dictations, 2)
        XCTAssertEqual(store.stats.monthly["2026-07"]?.words, 30)
        XCTAssertEqual(store.stats.monthly["2026-07"]?.duration, 11)
        XCTAssertEqual(store.stats.monthly["2026-08"]?.words, 4)
    }

    func testTopWordsTokenizerFiltersStopwordsAndShorts() {
        let tokens = StatsStore.tokenize("The quick brown fox, and the lazy DOG. I am 42 ok")
        // stopwords (the, and, i, am, ok), shorts (<3: fox is 3 keeps; "42" numeric dropped)
        XCTAssertTrue(tokens.contains("quick"))
        XCTAssertTrue(tokens.contains("brown"))
        XCTAssertTrue(tokens.contains("fox"))
        XCTAssertTrue(tokens.contains("lazy"))
        XCTAssertTrue(tokens.contains("dog"))       // lowercased
        XCTAssertFalse(tokens.contains("the"))
        XCTAssertFalse(tokens.contains("and"))
        XCTAssertFalse(tokens.contains("42"))       // pure number dropped
        XCTAssertFalse(tokens.contains("ok"))
    }

    func testComputeRecapTopAppsAndWords() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StatsStore(paths: paths)
        let now = date(2026, 7, 15)

        // Safari dominates apps; "swift" dominates words.
        store.recordDictation(words: 3, duration: 1, appName: "Safari", bundleId: "com.apple.Safari", text: "swift swift swift", now: now)
        store.recordDictation(words: 3, duration: 1, appName: "Safari", bundleId: "com.apple.Safari", text: "swift concurrency actor", now: now)
        store.recordDictation(words: 2, duration: 1, appName: "Xcode", bundleId: "com.apple.dt.Xcode", text: "actor model", now: now)

        let recap = store.computeRecap(month: "2026-07", topN: 5, now: now)
        XCTAssertEqual(recap.words, 8)
        XCTAssertEqual(recap.dictations, 3)
        XCTAssertEqual(recap.topApps.first?.bundleId, "com.apple.Safari")
        XCTAssertEqual(recap.topApps.first?.count, 2)
        XCTAssertEqual(recap.topWords.first?.word, "swift")
        XCTAssertEqual(recap.topWords.first?.count, 4)
        XCTAssertFalse(recap.isEmpty)
    }

    func testComputeRecapEmptyMonth() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StatsStore(paths: paths)
        let recap = store.computeRecap(month: "2020-01")
        XCTAssertTrue(recap.isEmpty)
        XCTAssertEqual(recap.words, 0)
        XCTAssertEqual(recap.dictations, 0)
    }

    // MARK: - Streaks

    func testCurrentStreak() {
        let now = date(2026, 7, 16)
        let ts = [
            transcript(daysBefore: 0, from: now),
            transcript(daysBefore: 1, from: now),
            transcript(daysBefore: 2, from: now),
            transcript(daysBefore: 5, from: now)   // gap
        ]
        XCTAssertEqual(StatsStore.computeStreak(from: ts, now: now), 3)
    }

    func testCurrentStreakBreaksWithNoRecentDay() {
        let now = date(2026, 7, 16)
        let ts = [transcript(daysBefore: 3, from: now), transcript(daysBefore: 4, from: now)]
        XCTAssertEqual(StatsStore.computeStreak(from: ts, now: now), 0)
    }

    func testLongestStreak() {
        let now = date(2026, 7, 16)
        // A 4-day run in the past, plus a 2-day recent run.
        let ts = [
            transcript(daysBefore: 20, from: now),
            transcript(daysBefore: 21, from: now),
            transcript(daysBefore: 22, from: now),
            transcript(daysBefore: 23, from: now),
            transcript(daysBefore: 0, from: now),
            transcript(daysBefore: 1, from: now)
        ]
        XCTAssertEqual(StatsStore.computeLongestStreak(from: ts), 4)
    }

    func testRecomputeUpdatesLongestStreakHighWaterMark() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StatsStore(paths: paths)
        let now = Date()
        let ts = [
            transcript(daysBefore: 10, from: now),
            transcript(daysBefore: 11, from: now),
            transcript(daysBefore: 12, from: now)
        ]
        store.recompute(from: ts)
        XCTAssertEqual(store.stats.longestStreak, 3)

        // A later recompute with a shorter history must not lower the high-water mark.
        store.recompute(from: [transcript(daysBefore: 0, from: now)])
        XCTAssertEqual(store.stats.longestStreak, 3)
    }

    // MARK: - Notifier body / month labels

    func testMonthLabel() {
        XCTAssertEqual(StatsStore.monthLabel(for: "2026-07"), "July 2026")
        XCTAssertEqual(StatsStore.monthLabel(for: "garbage"), "garbage")
    }

    func testRecapNotifierBody() {
        let recap = RecapSummary(
            monthKey: "2026-07", monthLabel: "July 2026",
            words: 4210, dictations: 132, timeSavedSeconds: 2460,
            topApps: [], topWords: [], currentStreak: 6, longestStreak: 9)
        let body = RecapNotifier.body(for: recap)
        XCTAssertTrue(body.contains("4,210 words"))
        XCTAssertTrue(body.contains("132 dictations"))
        XCTAssertTrue(body.contains("41 min"))
        XCTAssertTrue(body.contains("Streak: 6 days"))
    }

    func testNotifierGuardsOncePerMonthAndTargetsPreviousMonth() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = StatsStore(paths: paths)

        let june = date(2026, 6, 10)
        store.recordDictation(words: 10, duration: 5, appName: "A", bundleId: "a", text: "hello world", now: june)

        // Pass a nil center so no real notification is posted (headless-safe).
        let notifier = RecapNotifier(stats: store, center: nil)
        let julyNow = date(2026, 7, 5)

        notifier.checkAndNotify(now: julyNow)
        // Targets the *previous* month (June).
        XCTAssertEqual(store.stats.lastRecapMonthKey, "2026-06")

        // A second call in the same month is a no-op (guard holds).
        store.stats.lastRecapMonthKey = "2026-06"
        notifier.checkAndNotify(now: julyNow)
        XCTAssertEqual(store.stats.lastRecapMonthKey, "2026-06")
    }

    // MARK: - Helpers

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private func transcript(daysBefore: Int, from now: Date) -> Transcript {
        let day = Calendar.current.date(byAdding: .day, value: -daysBefore, to: now)!
        return Transcript(text: "sample text here",
                          recordingDuration: 2,
                          date: day.timeIntervalSinceReferenceDate)
    }
}
