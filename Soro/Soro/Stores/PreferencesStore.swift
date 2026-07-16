import Foundation
import Combine

/// JSON-backed store for `Preferences/preferences.json`.
@MainActor
final class PreferencesStore: ObservableObject {
    @Published var prefs: Preferences

    private let paths: AppPaths

    init(paths: AppPaths = .live) {
        self.paths = paths
        self.prefs = JSONFile.read(Preferences.self, from: paths.preferencesFile) ?? .default
    }

    func save() {
        try? JSONFile.write(prefs, to: paths.preferencesFile)
    }
}
