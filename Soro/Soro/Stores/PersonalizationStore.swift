import Foundation
import Combine

/// JSON-backed store for `Preferences/personalization_preferences.json`.
@MainActor
final class PersonalizationStore: ObservableObject {
    @Published var prefs: PersonalizationPreferences

    private let paths: AppPaths

    init(paths: AppPaths = .live) {
        self.paths = paths
        self.prefs = JSONFile.read(PersonalizationPreferences.self,
                                   from: paths.personalizationFile) ?? .default
    }

    func save() {
        try? JSONFile.write(prefs, to: paths.personalizationFile)
    }

    /// The (messaging style, scribe style, personal tweak) for a context bucket (§5).
    func styleFor(_ ctx: DictationContext) -> (messaging: String, scribe: String, tweak: String) {
        switch ctx {
        case .work:
            return (prefs.workMessagingStyle, prefs.workScribeWritingStyle, prefs.workPersonalTweak)
        case .email:
            return (prefs.emailStyle, prefs.emailScribeWritingStyle, prefs.emailPersonalTweak)
        case .casual:
            return (prefs.casualMessagingStyle, prefs.casualScribeWritingStyle, prefs.casualPersonalTweak)
        case .other:
            return (prefs.otherStyle, prefs.otherScribeWritingStyle, prefs.otherPersonalTweak)
        }
    }
}
