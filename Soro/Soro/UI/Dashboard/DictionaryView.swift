import SwiftUI

// MARK: - DictionaryView

/// Personal Dictionary screen (brief §4b / M8-dictionary).
///
/// Two tabs:
///  - Personal Terms  — `isReplacement == false`
///  - Personal Shortcuts — `isReplacement == true`
///
/// Each tab shows a searchable chip grid, a + Add button, per-chip edit/delete,
/// and an Auto-Learned suggestions row (sourced from AutoDictionaryStore).
struct DictionaryView: View {
    @EnvironmentObject private var glossary: GlossaryStore
    @EnvironmentObject private var autoDict: AutoDictionaryStore

    @State private var selectedTab: DictionaryTab = .terms
    @State private var searchText: String = ""
    @State private var showAddSheet: Bool = false
    @State private var editingEntry: GlossaryEntry? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SoroTheme.Spacing.xl) {
                // ── Header ────────────────────────────────────────────────
                ScreenHeader(
                    title: "Personal Dictionary",
                    subtitle: "Add words, names, or phrases Soro should recognize or expand. Terms improve transcription accuracy; shortcuts replace what you say with custom text."
                )

                // ── Tab + Search bar ──────────────────────────────────────
                HStack(spacing: 12) {
                    Picker("Tab", selection: $selectedTab) {
                        ForEach(DictionaryTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    Spacer()

                    PillSearchField(text: $searchText, prompt: "Search terms")
                        .frame(maxWidth: 200)

                    Button {
                        editingEntry = nil
                        showAddSheet = true
                    } label: {
                        Label("Add Term", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SoroTheme.accent)
                }

                // ── Content ───────────────────────────────────────────────
                VStack(alignment: .leading, spacing: SoroTheme.Spacing.xl) {
                    // Auto-Learned suggestions row (shown in both tabs when not filtered)
                    if searchText.isEmpty {
                        AutoLearnedSuggestionsRow(selectedTab: selectedTab)
                    }

                    // Chip grid
                    DictionaryChipGrid(
                        entries: filteredEntries,
                        onEdit: { entry in
                            editingEntry = entry
                            showAddSheet = true
                        },
                        onDelete: { entry in
                            glossary.delete(id: entry.id)
                        },
                        onToggle: { entry in
                            var updated = entry
                            updated.isEnabled.toggle()
                            glossary.update(updated)
                        }
                    )
                    .soroCard()
                }
            }
            .padding(SoroTheme.Spacing.screen)
        }
        .background(SoroTheme.canvas)
        .sheet(isPresented: $showAddSheet) {
            AddTermSheet(
                editing: editingEntry,
                tab: selectedTab
            ) { result in
                switch result {
                case .add(let entry):
                    glossary.add(entry)
                case .update(let entry):
                    glossary.update(entry)
                }
            }
        }
    }

    // MARK: - Filtering

    private var filteredEntries: [GlossaryEntry] {
        let tabFiltered = glossary.entries.filter { entry in
            entry.isReplacement == (selectedTab == .shortcuts)
        }
        guard !searchText.isEmpty else { return tabFiltered }
        let q = searchText.lowercased()
        return tabFiltered.filter { entry in
            entry.term.lowercased().contains(q) ||
            (entry.replacement?.lowercased().contains(q) ?? false)
        }
    }
}

// MARK: - Tab enum

enum DictionaryTab: String, CaseIterable, Identifiable {
    case terms = "terms"
    case shortcuts = "shortcuts"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terms:     return "Personal Terms"
        case .shortcuts: return "Personal Shortcuts"
        }
    }
}

// MARK: - PillSearchField

/// Willow-style pill search field, shared across dashboard screens.
struct PillSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SoroTheme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button {
                    text = ""
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
        .background(Capsule(style: .continuous).fill(SoroTheme.card))
        .overlay(Capsule(style: .continuous).strokeBorder(SoroTheme.hairline, lineWidth: 1))
    }
}

// MARK: - AutoLearnedSuggestionsRow

/// A prominent card surfacing auto-learned jargon / proper-noun suggestions.
///
/// Shown at the top of the Terms tab when there are pending suggestions so the user
/// sees them before scrolling through existing entries.
private struct AutoLearnedSuggestionsRow: View {
    @EnvironmentObject private var glossary: GlossaryStore
    @EnvironmentObject private var autoDict: AutoDictionaryStore

    let selectedTab: DictionaryTab

    // Only show in Terms tab — auto-learned terms are never replacements.
    private var shouldShow: Bool { selectedTab == .terms }

    private var pendingSuggestions: [String] {
        let alreadyAdded = Set(glossary.entries.map { $0.term.lowercased() })
        return autoDict.suggestions().filter { !alreadyAdded.contains($0.lowercased()) }
    }

    var body: some View {
        if shouldShow && !pendingSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // ── Header bar ─────────────────────────────────────────────
                HStack(spacing: 10) {
                    AccentIconTile(systemImage: "sparkles", size: 30, symbolSize: 13, filled: true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Suggested from your speech")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text("Tap + to add a term, × to dismiss")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Count badge
                    Text("\(pendingSuggestions.count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(SoroTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(SoroTheme.accent.opacity(0.12))
                        )
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()
                    .padding(.horizontal, 14)

                // ── Chip flow ──────────────────────────────────────────────
                FlowLayout(spacing: 8) {
                    ForEach(pendingSuggestions, id: \.self) { word in
                        SuggestionChip(word: word) {
                            let entry = GlossaryEntry(
                                term: word,
                                tag: "Auto-Learned",
                                isEnabled: true,
                                isReplacement: false
                            )
                            glossary.add(entry)
                        } onDismiss: {
                            autoDict.dismiss(word)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: SoroTheme.Radius.card, style: .continuous)
                    .fill(SoroTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: SoroTheme.Radius.card, style: .continuous)
                            .strokeBorder(SoroTheme.accent.opacity(0.30), lineWidth: 1.5)
                    )
                    .shadow(color: SoroTheme.accent.opacity(0.10), radius: 10, y: 4)
            )
        }
    }
}

// MARK: - SuggestionChip

private struct SuggestionChip: View {
    let word: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(word)
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 2) {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(SoroTheme.accent)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Add to dictionary")

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Dismiss suggestion")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(SoroTheme.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(SoroTheme.accent.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - DictionaryChipGrid

private struct DictionaryChipGrid: View {
    let entries: [GlossaryEntry]
    let onEdit: (GlossaryEntry) -> Void
    let onDelete: (GlossaryEntry) -> Void
    let onToggle: (GlossaryEntry) -> Void

    var body: some View {
        if entries.isEmpty {
            EmptyDictionaryState()
        } else {
            FlowLayout(spacing: 8) {
                ForEach(entries) { entry in
                    TermChip(
                        entry: entry,
                        onEdit: { onEdit(entry) },
                        onDelete: { onDelete(entry) },
                        onToggle: { onToggle(entry) }
                    )
                }
            }
        }
    }
}

// MARK: - TermChip

private struct TermChip: View {
    let entry: GlossaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    @State private var hovered = false

    var chipBackground: Color {
        if !entry.isEnabled { return Color.secondary.opacity(0.08) }
        if entry.tag == "Auto-Learned" { return SoroTheme.accent.opacity(0.08) }
        return SoroTheme.accent.opacity(0.12)
    }

    var chipBorder: Color {
        if !entry.isEnabled { return Color.secondary.opacity(0.15) }
        if entry.tag == "Auto-Learned" { return SoroTheme.accent.opacity(0.25) }
        return SoroTheme.accent.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Auto-learned tag indicator
            if entry.tag == "Auto-Learned" {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(SoroTheme.accent.opacity(0.7))
            }

            // Term
            Text(entry.term)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(entry.isEnabled ? .primary : .secondary)

            // Replacement arrow for shortcuts
            if entry.isReplacement, let replacement = entry.replacement, !replacement.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(replacement)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 120)
                }
            }

            // Hover controls
            if hovered {
                HStack(spacing: 2) {
                    Button(action: onToggle) {
                        Image(systemName: entry.isEnabled ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isEnabled ? "Disable" : "Enable")

                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(chipBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(chipBorder, lineWidth: 1)
                )
        )
        .opacity(entry.isEnabled ? 1.0 : 0.55)
        .animation(.easeInOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Edit") { onEdit() }
            Button(entry.isEnabled ? "Disable" : "Enable") { onToggle() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - EmptyDictionaryState

private struct EmptyDictionaryState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 36))
                .foregroundStyle(SoroTheme.accent.opacity(0.4))
            Text("No entries yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap + Add Term to add your first entry.")
                .font(.callout)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - AddTermSheet result

enum AddTermResult {
    case add(GlossaryEntry)
    case update(GlossaryEntry)
}

// MARK: - AddTermSheet

struct AddTermSheet: View {
    let editing: GlossaryEntry?
    let tab: DictionaryTab
    let onCommit: (AddTermResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var term: String = ""
    @State private var replacement: String = ""
    @State private var isReplacement: Bool = false
    @State private var isEnabled: Bool = true

    private var isEditing: Bool { editing != nil }
    private var isValid: Bool {
        !term.trimmingCharacters(in: .whitespaces).isEmpty &&
        (!isReplacement || !replacement.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Entry" : "Add to Dictionary")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // Form
            VStack(alignment: .leading, spacing: 16) {
                // Term field
                VStack(alignment: .leading, spacing: 5) {
                    Text("Term")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextField(
                        isReplacement ? "Spoken phrase (e.g. my email)" : "Word or name (e.g. Supabase)",
                        text: $term
                    )
                    .textFieldStyle(.roundedBorder)
                }

                // Type toggle
                VStack(alignment: .leading, spacing: 5) {
                    Text("Type")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker("Type", selection: $isReplacement) {
                        Text("Term — improve recognition").tag(false)
                        Text("Shortcut — expand to text").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }

                // Replacement field (only for shortcuts)
                if isReplacement {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Expands to")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("Replacement text (e.g. jordan@chigbo.net)", text: $replacement)
                            .textFieldStyle(.roundedBorder)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Enable toggle
                Toggle("Enabled", isOn: $isEnabled)
                    .tint(SoroTheme.accent)
            }
            .padding(20)
            .animation(.easeInOut(duration: 0.18), value: isReplacement)

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add") {
                    commit()
                }
                .buttonStyle(.borderedProminent)
                .tint(SoroTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 380, maxWidth: 480)
        .onAppear { populate() }
    }

    private func populate() {
        if let entry = editing {
            term = entry.term
            isReplacement = entry.isReplacement
            replacement = entry.replacement ?? ""
            isEnabled = entry.isEnabled
        } else {
            // Pre-select tab type
            isReplacement = (tab == .shortcuts)
        }
    }

    private func commit() {
        let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespaces)

        if let existing = editing {
            var updated = existing
            updated.term = trimmedTerm
            updated.isReplacement = isReplacement
            updated.replacement = isReplacement ? trimmedReplacement : nil
            updated.isEnabled = isEnabled
            onCommit(.update(updated))
        } else {
            let entry = GlossaryEntry(
                term: trimmedTerm,
                tag: "My Terms",
                isEnabled: isEnabled,
                isReplacement: isReplacement,
                replacement: isReplacement ? trimmedReplacement : nil
            )
            onCommit(.add(entry))
        }
        dismiss()
    }
}

// MARK: - FlowLayout

/// A simple wrapping layout for chip grids.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }
        return CGSize(
            width: min(maxWidth, width),
            height: currentY + lineHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        var lineSubviews: [(subview: LayoutSubview, size: CGSize, x: CGFloat)] = []

        func placeLine() {
            for item in lineSubviews {
                item.subview.place(
                    at: CGPoint(x: item.x, y: currentY),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.minX + width && currentX > bounds.minX {
                placeLine()
                lineSubviews.removeAll()
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            lineSubviews.append((subview, size, currentX))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }
        placeLine()
    }
}
