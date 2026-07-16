import Foundation

/// Resolves the on-disk layout under
/// `~/Library/Application Support/com.jordanchigbo.soro/` (brief §6).
///
/// Injectable root so tests can point at a temp dir.
struct AppPaths {
    let root: URL

    static let bundleId = "com.jordanchigbo.soro"

    /// Legacy bundle id used before the rename to Soro. History, dictionary, and
    /// preferences are migrated forward from this directory on first launch.
    static let legacyBundleId = "net.chigbo.whispaa"

    /// Default production location.
    static let live: AppPaths = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return AppPaths(root: base.appendingPathComponent(bundleId, isDirectory: true))
    }()

    /// Legacy (pre-rename) production location.
    static let legacy: AppPaths = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return AppPaths(root: base.appendingPathComponent(legacyBundleId, isDirectory: true))
    }()

    var preferences: URL { root.appendingPathComponent("Preferences", isDirectory: true) }
    var transcripts: URL { root.appendingPathComponent("Transcripts", isDirectory: true) }
    var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    var models: URL { root.appendingPathComponent("Models", isDirectory: true) }

    var preferencesFile: URL { preferences.appendingPathComponent("preferences.json") }
    var glossaryFile: URL { preferences.appendingPathComponent("glossary.json") }
    var personalizationFile: URL { preferences.appendingPathComponent("personalization_preferences.json") }
    var autoDictionaryFile: URL { preferences.appendingPathComponent("auto_dictionary_cache.json") }
    var statsFile: URL { preferences.appendingPathComponent("feature_usage_stats.json") }

    func transcriptFile(id: UUID) -> URL {
        transcripts.appendingPathComponent("\(id.uuidString).json")
    }

    /// Ensures all directories exist.
    func ensureDirectories() {
        let fm = FileManager.default
        for dir in [preferences, transcripts, recordings, models] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// One-time migration of user data from the pre-rename bundle directory
/// (`net.chigbo.whispaa`) to the new one (`com.jordanchigbo.soro`).
///
/// Best-effort: any failure is ignored so a broken copy never blocks launch.
enum DataMigration {
    /// Pure decision: migrate only when the old directory exists and the new one
    /// does not. Extracted for testability.
    static func shouldMigrate(oldExists: Bool, newExists: Bool) -> Bool {
        oldExists && !newExists
    }

    /// Runs the migration once at startup. Recursively copies the legacy
    /// directory to the new location if appropriate. Safe to call every launch.
    static func migrateIfNeeded(from old: AppPaths = .legacy,
                                to new: AppPaths = .live,
                                fileManager fm: FileManager = .default) {
        let oldExists = fm.fileExists(atPath: old.root.path)
        let newExists = fm.fileExists(atPath: new.root.path)
        guard shouldMigrate(oldExists: oldExists, newExists: newExists) else { return }
        do {
            try fm.createDirectory(at: new.root.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: old.root, to: new.root)
        } catch {
            // Ignore — a fresh directory will be created on demand by the stores.
        }
    }
}

/// Shared JSON helpers used by every store. All writes are atomic (temp+rename via `.atomic`).
enum JSONFile {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try encoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
