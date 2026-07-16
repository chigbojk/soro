import SwiftUI

/// Home screen (brief §4b): header, 4 stat cards, searchable virtualized History list.
///
/// Receives its data via @EnvironmentObject:
///   - TranscriptStore  — history paging + search
///   - StatsStore       — derived stat values
///   - PreferencesStore — current hotkey name for the header
struct HomeView: View {
    @EnvironmentObject private var transcriptStore: TranscriptStore
    @EnvironmentObject private var statsStore: StatsStore
    @EnvironmentObject private var preferencesStore: PreferencesStore

    @StateObject private var frontmostApp = FrontmostAppProvider()

    // Closures injected at the call site for actions that depend on later milestones.
    // Default to no-ops so the view compiles and runs without M3/audio playback.
    var onReinsert: (Transcript) -> Void = { _ in }
    var onPlayAudio: (Transcript) -> Void = { _ in }

    // MARK: - State

    @State private var searchText: String = ""
    @State private var loadedTranscripts: [Transcript] = []
    @State private var isLoadingMore: Bool = false
    @State private var hasMore: Bool = true

    /// The `"yyyy-MM"` recap month the user has dismissed on Home (persisted so the card
    /// stays dismissed until a new month rolls around). Empty = not dismissed.
    @AppStorage("home.recapDismissedMonth") private var recapDismissedMonth: String = ""

    private let pageSize = 40

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                headerSection
                    .padding(.horizontal, SoroTheme.Spacing.screen)
                    .padding(.top, SoroTheme.Spacing.screen)
                    .padding(.bottom, SoroTheme.Spacing.xl)

                statsSection
                    .padding(.horizontal, SoroTheme.Spacing.screen)
                    .padding(.bottom, SoroTheme.Spacing.xl)

                recapSection

                historySection
                    .padding(.horizontal, SoroTheme.Spacing.screen)
                    .padding(.bottom, SoroTheme.Spacing.screen)
            }
        }
        .background(SoroTheme.canvas)
        .onAppear {
            loadInitial()
            frontmostApp.start()
        }
        .onDisappear { frontmostApp.stop() }
        .onChange(of: searchText) { _ in reloadForSearch() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Hold")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SoroTheme.textPrimary)

                    KeycapPill(label: hotkeyKeycapLabel)

                    Text("to dictate")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SoroTheme.textPrimary)

                    if let name = frontmostApp.frontmostName {
                        Text("on")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(SoroTheme.textPrimary)
                        Text(name)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(SoroTheme.accent)
                            .lineLimit(1)
                    }
                }

            }

            Spacer(minLength: 0)

            appIconStack
        }
    }

    /// A tasteful cluster of overlapping running-app icons.
    @ViewBuilder
    private var appIconStack: some View {
        if !frontmostApp.icons.isEmpty {
            HStack(spacing: -10) {
                ForEach(frontmostApp.icons) { icon in
                    Image(nsImage: icon.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
            }
        }
    }

    private var statsSection: some View {
        let columns = [
            GridItem(.flexible(), spacing: SoroTheme.Spacing.md),
            GridItem(.flexible(), spacing: SoroTheme.Spacing.md),
            GridItem(.flexible(), spacing: SoroTheme.Spacing.md),
            GridItem(.flexible(), spacing: SoroTheme.Spacing.md)
        ]
        return LazyVGrid(columns: columns, spacing: SoroTheme.Spacing.md) {
            StatCardView(
                title: "Dictated words",
                value: formatNumber(statsStore.dictatedWords),
                systemImage: "text.word.spacing",
                tint: SoroTheme.accent
            )
            StatCardView(
                title: "Time saved",
                value: formatTimeSaved(statsStore.timeSavedSeconds),
                systemImage: "clock.badge.checkmark",
                tint: Color(red: 0x1F/255, green: 0xA9/255, blue: 0x7A/255)
            )
            StatCardView(
                title: "Day streak",
                value: "\(statsStore.dayStreak)",
                systemImage: "flame.fill",
                tint: Color(red: 0xF0/255, green: 0x7B/255, blue: 0x3F/255)
            )
            StatCardView(
                title: "Average speed",
                value: "\(statsStore.avgWPM)",
                unit: "wpm",
                systemImage: "speedometer",
                tint: Color(red: 0x2E/255, green: 0x7C/255, blue: 0xE6/255)
            )
        }
    }

    /// The dismissible "This month" recap highlight. Hidden when there's nothing to show
    /// this month or when the user has dismissed it for the current month.
    @ViewBuilder
    private var recapSection: some View {
        let currentMonth = UsageStats.monthKey(for: Date())
        let recap = statsStore.computeRecap(month: currentMonth)
        if !recap.isEmpty && recapDismissedMonth != currentMonth {
            RecapCard(recap: recap) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recapDismissedMonth = currentMonth
                }
            }
            .padding(.horizontal, SoroTheme.Spacing.screen)
            .padding(.bottom, SoroTheme.Spacing.xl)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: SoroTheme.Spacing.md) {
            HStack {
                Text("History")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SoroTheme.textPrimary)
                Spacer()
                searchField
            }

            if loadedTranscripts.isEmpty && !searchText.isEmpty {
                noResultsView
            } else if loadedTranscripts.isEmpty {
                emptyHistoryView
            } else {
                historyList
                    .soroCard(padding: 10)
            }
        }
    }

    /// Willow-style pill search field.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SoroTheme.textTertiary)
            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SoroTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(SoroTheme.card)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(SoroTheme.hairline, lineWidth: 1)
        )
    }

    private var historyList: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groupedTranscripts, id: \.0) { day, items in
                Section {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, transcript in
                        HistoryRowView(
                            transcript: transcript,
                            onCopy: { copyTranscript($0) },
                            onDelete: { deleteTranscript($0) },
                            onReinsert: onReinsert,
                            onPlayAudio: onPlayAudio
                        )
                        if idx < items.count - 1 {
                            Divider()
                                .padding(.leading, 84)
                                .opacity(0.5)
                        }
                    }
                } header: {
                    dayHeader(day)
                }
            }

            // Load-more trigger — fires when the last row comes into view.
            if hasMore && !isLoadingMore && searchText.isEmpty {
                Color.clear
                    .frame(height: 1)
                    .onAppear { loadNextPage() }
            }

            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 12)
                    Spacer()
                }
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(SoroTheme.textTertiary)
            Text("No results for \"\(searchText)\"")
                .font(.system(size: 13))
                .foregroundStyle(SoroTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .soroCard()
    }

    private var emptyHistoryView: some View {
        VStack(spacing: 10) {
            AccentIconTile(systemImage: "mic.fill", size: 48, symbolSize: 22, filled: true)
            Text("No dictations yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SoroTheme.textPrimary)
            Text("Hold \(hotkeyDisplayName) anywhere to start dictating.")
                .font(.system(size: 12))
                .foregroundStyle(SoroTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .soroCard()
    }

    // MARK: - Day header

    private func dayHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(SoroTheme.textTertiary)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoroTheme.card)
    }

    // MARK: - Data loading

    private func loadInitial() {
        loadedTranscripts = transcriptStore.recent(limit: pageSize, offset: 0)
        hasMore = loadedTranscripts.count == pageSize
    }

    private func loadNextPage() {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        let offset = loadedTranscripts.count
        let page = transcriptStore.recent(limit: pageSize, offset: offset)
        loadedTranscripts.append(contentsOf: page)
        hasMore = page.count == pageSize
        isLoadingMore = false
    }

    /// Willow-style placeholder showing the total history count, e.g. "Search 9,703 histories".
    private var searchPlaceholder: String {
        let n = transcriptStore.count
        guard n > 0 else { return "Search history" }
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "Search \(formatted) \(n == 1 ? "history" : "histories")"
    }

    private func reloadForSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            loadInitial()
        } else {
            loadedTranscripts = transcriptStore.search(q, limit: 200)
            hasMore = false
        }
    }

    private func copyTranscript(_ t: Transcript) {
        guard t.text != Transcript.errorSentinel else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.text, forType: .string)
    }

    private func deleteTranscript(_ t: Transcript) {
        transcriptStore.delete(id: t.id)
        loadedTranscripts.removeAll { $0.id == t.id }
    }

    // MARK: - Grouping

    /// Groups loaded transcripts by day label ("Today", "Yesterday", formatted date).
    private var groupedTranscripts: [(String, [Transcript])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none

        var groups: [(String, [Transcript])] = []
        var currentLabel: String?
        var currentGroup: [Transcript] = []

        for t in loadedTranscripts {
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
                    groups.append((cl, currentGroup))
                }
                currentLabel = label
                currentGroup = [t]
            }
        }
        if let cl = currentLabel, !currentGroup.isEmpty {
            groups.append((cl, currentGroup))
        }
        return groups
    }

    // MARK: - Formatting helpers

    private var hotkeyDisplayName: String {
        preferencesStore.prefs.hotkeyData.keyName
    }

    /// A compact, glyph-friendly label for the header keycap (e.g. "⌥ Opt").
    private var hotkeyKeycapLabel: String {
        Self.keycapLabel(for: preferencesStore.prefs.hotkeyData.keyName)
    }

    /// Maps a modifier/key name to a compact keycap label with an SF-safe glyph.
    /// Pure/static so it can be unit-tested without any UI.
    static func keycapLabel(for keyName: String) -> String {
        let lower = keyName.lowercased()
        if lower.contains("option") { return "⌥ Opt" }
        if lower.contains("command") { return "⌘ Cmd" }
        if lower.contains("control") { return "⌃ Ctrl" }
        if lower.contains("shift") { return "⇧ Shift" }
        if lower.contains("function") || lower == "fn" { return "fn" }
        return keyName
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func formatTimeSaved(_ seconds: TimeInterval) -> String {
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
}
