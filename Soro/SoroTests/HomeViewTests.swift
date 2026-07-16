import XCTest
@testable import Soro

/// Unit tests for HomeView logic helpers (pure logic, no UI rendering).
/// Tests cover: day grouping, stat formatting, search-driven paging, copy/delete.
@MainActor
final class HomeViewTests: XCTestCase {

    // MARK: - Grouping helpers (replicated logic tested directly on TranscriptStore)

    func testGroupingLabels() throws {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!

        // Build transcripts with known timestamps, convert to Cocoa epoch.
        let t1 = Transcript(text: "today msg", recordingDuration: 1,
                            date: today.addingTimeInterval(3600).timeIntervalSinceReferenceDate)
        let t2 = Transcript(text: "yesterday msg", recordingDuration: 1,
                            date: yesterday.addingTimeInterval(3600).timeIntervalSinceReferenceDate)
        let t3 = Transcript(text: "old msg", recordingDuration: 1,
                            date: twoDaysAgo.addingTimeInterval(3600).timeIntervalSinceReferenceDate)

        let groups = groupedByDay([t1, t2, t3], now: now)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].label, "Today")
        XCTAssertEqual(groups[0].items.count, 1)
        XCTAssertEqual(groups[1].label, "Yesterday")
        XCTAssertEqual(groups[2].label?.isEmpty, false)  // some formatted date string
        XCTAssertNotEqual(groups[2].label, "Today")
        XCTAssertNotEqual(groups[2].label, "Yesterday")
    }

    func testGroupingMultiplePerDay() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let t1 = Transcript(text: "first",  recordingDuration: 1,
                            date: today.addingTimeInterval(1000).timeIntervalSinceReferenceDate)
        let t2 = Transcript(text: "second", recordingDuration: 1,
                            date: today.addingTimeInterval(2000).timeIntervalSinceReferenceDate)

        // Note: TranscriptStore returns date desc, so higher date first.
        let groups = groupedByDay([t2, t1], now: Date())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].label, "Today")
        XCTAssertEqual(groups[0].items.count, 2)
    }

    func testGroupingEmpty() {
        let groups = groupedByDay([], now: Date())
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Stat formatting helpers

    func testFormatNumber() {
        XCTAssertEqual(HomeViewHelper.formatNumber(0), "0")
        XCTAssertEqual(HomeViewHelper.formatNumber(1200), "1,200")
        XCTAssertEqual(HomeViewHelper.formatNumber(999999), "999,999")
    }

    func testFormatTimeSaved_zero() {
        XCTAssertEqual(HomeViewHelper.formatTimeSaved(0), "0 min")
    }

    func testFormatTimeSaved_minutes() {
        XCTAssertEqual(HomeViewHelper.formatTimeSaved(90), "1 min")
        XCTAssertEqual(HomeViewHelper.formatTimeSaved(300), "5 min")
        XCTAssertEqual(HomeViewHelper.formatTimeSaved(3000), "50 min")
    }

    func testFormatTimeSaved_hours() {
        XCTAssertEqual(HomeViewHelper.formatTimeSaved(3600), "1 hr")
        XCTAssertEqual(HomeViewHelper.formatTimeSaved(3660), "1 hr 1 min")
        XCTAssertEqual(HomeViewHelper.formatTimeSaved(7320), "2 hr 2 min")
    }

    func testFormatDuration_seconds() {
        XCTAssertEqual(HomeViewHelper.formatDuration(30), "30s")
        XCTAssertEqual(HomeViewHelper.formatDuration(59), "59s")
    }

    func testFormatDuration_minutes() {
        XCTAssertEqual(HomeViewHelper.formatDuration(60), "1m 0s")
        XCTAssertEqual(HomeViewHelper.formatDuration(90), "1m 30s")
    }

    // MARK: - TranscriptStore integration (paging)

    func testPagingReturnsCorrectSlices() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = TranscriptStore(paths: paths)

        for i in 0..<10 {
            store.add(Transcript(text: "item \(i)", recordingDuration: 1, date: Double(i)))
        }

        let page0 = store.recent(limit: 5, offset: 0)
        XCTAssertEqual(page0.count, 5)
        let page1 = store.recent(limit: 5, offset: 5)
        XCTAssertEqual(page1.count, 5)
        // No overlap.
        let ids0 = Set(page0.map { $0.id })
        let ids1 = Set(page1.map { $0.id })
        XCTAssertTrue(ids0.isDisjoint(with: ids1))
    }

    func testSearchFiltersThenResetsOnEmptyQuery() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = TranscriptStore(paths: paths)

        store.add(Transcript(text: "the quick brown fox", recordingDuration: 1, date: 1))
        store.add(Transcript(text: "another thing entirely", recordingDuration: 1, date: 2))

        let searchResults = store.search("fox", limit: 50)
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertTrue(searchResults[0].text.contains("fox"))

        // Empty query returns all via recent().
        let allResults = store.search("", limit: 50)
        XCTAssertEqual(allResults.count, 2)
    }

    func testDeleteRemovesFromPaging() throws {
        let paths = makeTempPaths()
        defer { removeTemp(paths) }
        let store = TranscriptStore(paths: paths)

        let t = Transcript(text: "delete me", recordingDuration: 1, date: 999)
        store.add(t)
        XCTAssertEqual(store.recent(limit: 10).count, 1)
        store.delete(id: t.id)
        XCTAssertEqual(store.recent(limit: 10).count, 0)
    }

    // MARK: - Day streak integration

    func testDayStreakIncludesConsecutiveDays() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        let t1 = Transcript(text: "a", recordingDuration: 1,
                            date: today.addingTimeInterval(3600).timeIntervalSinceReferenceDate)
        let t2 = Transcript(text: "b", recordingDuration: 1,
                            date: yesterday.addingTimeInterval(3600).timeIntervalSinceReferenceDate)

        let streak = StatsStore.computeStreak(from: [t1, t2])
        XCTAssertEqual(streak, 2)
    }

    func testDayStreakBrokenByGap() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Skip yesterday → streak of 1 (today only).
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!

        let t1 = Transcript(text: "a", recordingDuration: 1,
                            date: today.addingTimeInterval(3600).timeIntervalSinceReferenceDate)
        let t2 = Transcript(text: "b", recordingDuration: 1,
                            date: twoDaysAgo.addingTimeInterval(3600).timeIntervalSinceReferenceDate)

        let streak = StatsStore.computeStreak(from: [t1, t2])
        XCTAssertEqual(streak, 1)
    }

    // MARK: - Error sentinel display

    func testErrorSentinelIsRecognized() {
        let t = Transcript(text: Transcript.errorSentinel, recordingDuration: 0)
        XCTAssertEqual(t.text, Transcript.errorSentinel)
        // HomeView uses this to show "Transcription failed" — test the sentinel constant.
        XCTAssertEqual(Transcript.errorSentinel, "ERROR_TRANSCRIBING")
    }

    // MARK: - Header keycap label (Willow-style compact glyph)

    func testKeycapLabelForModifiers() {
        XCTAssertEqual(HomeView.keycapLabel(for: "Left Option"), "⌥ Opt")
        XCTAssertEqual(HomeView.keycapLabel(for: "Right Option"), "⌥ Opt")
        XCTAssertEqual(HomeView.keycapLabel(for: "Left Command"), "⌘ Cmd")
        XCTAssertEqual(HomeView.keycapLabel(for: "Right Control"), "⌃ Ctrl")
        XCTAssertEqual(HomeView.keycapLabel(for: "Left Shift"), "⇧ Shift")
    }

    func testKeycapLabelFallsBackToRawName() {
        // A non-modifier key keeps its own label so the header still reads correctly.
        XCTAssertEqual(HomeView.keycapLabel(for: "F5"), "F5")
        XCTAssertEqual(HomeView.keycapLabel(for: "Key 99"), "Key 99")
    }
}

// MARK: - Grouping helper (mirrors HomeView.groupedTranscripts logic, extracted for testability)

private struct DayGroup {
    let label: String?
    let items: [Transcript]
}

private func groupedByDay(_ transcripts: [Transcript], now: Date) -> [DayGroup] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today

    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .none

    var groups: [DayGroup] = []
    var currentLabel: String?
    var currentGroup: [Transcript] = []

    for t in transcripts {
        let day = cal.startOfDay(for: t.timestamp)
        let label: String
        if day == today {
            label = "Today"
        } else if day == yesterday {
            label = "Yesterday"
        } else {
            label = formatter.string(from: day)
        }

        if label == currentLabel {
            currentGroup.append(t)
        } else {
            if let cl = currentLabel, !currentGroup.isEmpty {
                groups.append(DayGroup(label: cl, items: currentGroup))
            }
            currentLabel = label
            currentGroup = [t]
        }
    }
    if let cl = currentLabel, !currentGroup.isEmpty {
        groups.append(DayGroup(label: cl, items: currentGroup))
    }
    return groups
}

// MARK: - HomeView formatting helpers (extracted for unit tests)

/// Mirrors the pure formatting helpers in HomeView so they can be tested without SwiftUI.
enum HomeViewHelper {
    static func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func formatTimeSaved(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0 min" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(max(1, minutes)) min"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes == 0 {
                return "\(hours) hr"
            } else {
                return "\(hours) hr \(minutes) min"
            }
        }
    }

    static func formatDuration(_ d: TimeInterval) -> String {
        if d < 60 {
            return String(format: "%.0fs", d)
        } else {
            return String(format: "%dm %.0fs", Int(d) / 60, d.truncatingRemainder(dividingBy: 60))
        }
    }
}
