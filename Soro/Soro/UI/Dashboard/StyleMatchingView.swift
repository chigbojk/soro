import SwiftUI

// MARK: - StyleMatchingView

/// Style Matching dashboard screen (brief §4b, §5).
/// Displays per-context cards for Work, Email, Casual, and Other.
/// Each card lets the user pick:
///   - Messaging style (formal / casual)
///   - Scribe writing style (natural / polished / concise)
///   - A freeform personal tweak that is injected verbatim into the Ollama prompt.
///
/// Bound to `PersonalizationStore` via @EnvironmentObject; saves on every change.
struct StyleMatchingView: View {
    @EnvironmentObject private var store: PersonalizationStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SoroTheme.Spacing.xl) {
                ScreenHeader(
                    title: "Style Matching",
                    subtitle: "Soro reads the active app to determine context and automatically adjusts tone, formality, and structure — so a Slack message sounds different from a work email without any extra commands."
                )

                // Per-context cards
                ContextCard(
                    context: .work,
                    label: "Work",
                    icon: "briefcase",
                    subtitle: "Cursor, VS Code, Notion, Linear, terminals, and any unrecognised productivity app.",
                    messagingStyle: Binding(
                        get: { store.prefs.workMessagingStyle },
                        set: { store.prefs.workMessagingStyle = $0; store.save() }),
                    scribeStyle: Binding(
                        get: { store.prefs.workScribeWritingStyle },
                        set: { store.prefs.workScribeWritingStyle = $0; store.save() }),
                    personalTweak: Binding(
                        get: { store.prefs.workPersonalTweak },
                        set: { store.prefs.workPersonalTweak = $0; store.save() }))

                ContextCard(
                    context: .email,
                    label: "Email",
                    icon: "envelope",
                    subtitle: "Mail, Gmail, and web-based mail clients.",
                    messagingStyle: Binding(
                        get: { store.prefs.emailStyle },
                        set: { store.prefs.emailStyle = $0; store.save() }),
                    scribeStyle: Binding(
                        get: { store.prefs.emailScribeWritingStyle },
                        set: { store.prefs.emailScribeWritingStyle = $0; store.save() }),
                    personalTweak: Binding(
                        get: { store.prefs.emailPersonalTweak },
                        set: { store.prefs.emailPersonalTweak = $0; store.save() }))

                ContextCard(
                    context: .casual,
                    label: "Casual",
                    icon: "bubble.left.and.bubble.right",
                    subtitle: "Messages, WhatsApp, Slack, Discord, Instagram, and similar chat apps.",
                    messagingStyle: Binding(
                        get: { store.prefs.casualMessagingStyle },
                        set: { store.prefs.casualMessagingStyle = $0; store.save() }),
                    scribeStyle: Binding(
                        get: { store.prefs.casualScribeWritingStyle },
                        set: { store.prefs.casualScribeWritingStyle = $0; store.save() }),
                    personalTweak: Binding(
                        get: { store.prefs.casualPersonalTweak },
                        set: { store.prefs.casualPersonalTweak = $0; store.save() }))

                ContextCard(
                    context: .other,
                    label: "Other",
                    icon: "square.dashed",
                    subtitle: "Every app that doesn't match a specific context above.",
                    messagingStyle: Binding(
                        get: { store.prefs.otherStyle },
                        set: { store.prefs.otherStyle = $0; store.save() }),
                    scribeStyle: Binding(
                        get: { store.prefs.otherScribeWritingStyle },
                        set: { store.prefs.otherScribeWritingStyle = $0; store.save() }),
                    personalTweak: Binding(
                        get: { store.prefs.otherPersonalTweak },
                        set: { store.prefs.otherPersonalTweak = $0; store.save() }))
            }
            .padding(SoroTheme.Spacing.screen)
        }
        .background(SoroTheme.canvas)
    }
}

// MARK: - ContextCard

/// A rounded card for one context bucket (Work / Email / Casual / Other).
private struct ContextCard: View {
    let context: DictationContext
    let label: String
    let icon: String
    let subtitle: String

    @Binding var messagingStyle: String
    @Binding var scribeStyle: String
    @Binding var personalTweak: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Card header
            HStack(spacing: 12) {
                AccentIconTile(systemImage: icon, size: 34, symbolSize: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SoroTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SoroTheme.textSecondary)
                }

                Spacer()
            }

            Divider()

            // Messaging style picker
            StyleRow(
                title: "Messaging style",
                description: "Sets the overall formality level passed to the AI cleanup prompt.",
                selection: $messagingStyle,
                options: MessagingStyleOption.allCases,
                optionLabel: { $0.label },
                optionValue: { $0.value })

            // Scribe writing style picker
            StyleRow(
                title: "Scribe writing style",
                description: "Controls how the AI structures and refines your dictated text.",
                selection: $scribeStyle,
                options: ScribeStyleOption.allCases,
                optionLabel: { $0.label },
                optionValue: { $0.value })

            // Personal tweak text field
            PersonalTweakField(text: $personalTweak, context: label)
        }
        .soroCard(padding: SoroTheme.Spacing.xl)
    }
}

// MARK: - StyleRow

/// A labelled picker row used for both messaging style and scribe writing style.
private struct StyleRow<Option: Hashable>: View {
    let title: String
    let description: String
    @Binding var selection: String
    let options: [Option]
    let optionLabel: (Option) -> String
    let optionValue: (Option) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                // Segmented-style picker using a Picker with .segmented style
                Picker("", selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(optionLabel(option)).tag(optionValue(option))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PersonalTweakField

/// A freeform instruction field injected verbatim into the Ollama system prompt
/// (maps to the `[PERSONAL_TWEAK]` placeholder in Appendix B).
private struct PersonalTweakField: View {
    @Binding var text: String
    let context: String

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Personal tweak")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if !text.isEmpty {
                    Button("Clear") { text = "" }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(SoroTheme.accent)
                }
            }
            TextField(
                "e.g. Always end with a friendly sign-off.",
                text: $text,
                axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($isFocused)

            Text("This instruction is appended verbatim to the AI prompt for \(context) context. Use it to enforce style quirks the other settings don't cover.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Option enumerations

private enum MessagingStyleOption: CaseIterable, Hashable {
    case formal, casual

    var label: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        }
    }

    var value: String {
        switch self {
        case .formal: return "formal"
        case .casual: return "casual"
        }
    }
}

private enum ScribeStyleOption: CaseIterable, Hashable {
    case natural, polished, concise

    var label: String {
        switch self {
        case .natural:  return "Natural"
        case .polished: return "Polished"
        case .concise:  return "Concise"
        }
    }

    var value: String {
        switch self {
        case .natural:  return "natural"
        case .polished: return "polished"
        case .concise:  return "concise"
        }
    }
}
