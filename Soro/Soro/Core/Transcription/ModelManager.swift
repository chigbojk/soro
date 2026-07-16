import Foundation

/// One curated Whisper (STT) model the user can pick and download from Settings.
///
/// Add a new option by appending to `ModelManager.curatedModels` — the picker,
/// download flow, and install-state detection all read from that single list,
/// so the catalogue is trivial to extend without touching any UI code.
struct WhisperModelOption: Identifiable, Equatable, Sendable {
    /// The WhisperKit model id (also the on-disk folder name), e.g.
    /// `openai_whisper-small.en`. Doubles as the stable `Identifiable` id.
    let id: String
    /// Short human label shown in the picker, e.g. "Small (English)".
    let name: String
    /// Approximate on-disk footprint, e.g. "~244 MB".
    let sizeHint: String
    /// One-line speed/accuracy trade-off shown under the label.
    let qualityHint: String

    var modelName: String { id }
}

/// Manages Whisper model download/selection under `Models/` (brief §3b, App A).
struct ModelManager {
    let paths: AppPaths

    /// Default model. `small.en` is the accuracy/speed sweet spot on Apple Silicon —
    /// `base.en` (the original default) garbles short/mumbled clips badly.
    static let defaultModel = "openai_whisper-small.en"

    /// The curated "sensible defaults" catalogue surfaced in Settings (brief §3b).
    /// Ordered fastest → most accurate. Easy to extend: append a `WhisperModelOption`.
    static let curatedModels: [WhisperModelOption] = [
        WhisperModelOption(
            id: "openai_whisper-base.en",
            name: "Base (English)",
            sizeHint: "~75 MB",
            qualityHint: "Fastest, good for short clear speech"),
        WhisperModelOption(
            id: "openai_whisper-small.en",
            name: "Small (English)",
            sizeHint: "~244 MB",
            qualityHint: "Balanced speed & accuracy (recommended)"),
        WhisperModelOption(
            id: "openai_whisper-small",
            name: "Small (Multilingual)",
            sizeHint: "~244 MB",
            qualityHint: "Balanced, non-English languages"),
        WhisperModelOption(
            id: "openai_whisper-medium.en",
            name: "Medium (English)",
            sizeHint: "~769 MB",
            qualityHint: "Most accurate, slower on older Macs"),
    ]

    /// Flat list of curated model names (WhisperKit ids). Preserved for callers
    /// that only need names (e.g. warm-up / picker tags).
    static let availableModels: [String] = curatedModels.map(\.id)

    /// Look up a curated option by its WhisperKit id, if present.
    static func curatedModel(id: String) -> WhisperModelOption? {
        curatedModels.first { $0.id == id }
    }

    /// Resolve the model that should actually be prepared/used, given the
    /// user's persisted preference. Falls back to `defaultModel` when the stored
    /// value is empty or unknown so callers never end up with a bogus id.
    ///
    /// Wiring: `AppState` warm-up and the coordinator read this instead of the
    /// hardcoded `defaultModel` — see docs/integration/model-management.md.
    static func selectedModel(from prefs: Preferences) -> String {
        let stored = prefs.whisperModel
        if !stored.isEmpty { return stored }
        return defaultModel
    }

    init(paths: AppPaths = .live) {
        self.paths = paths
    }

    /// The on-disk folder WhisperKit downloads a variant into
    /// (`Models/models/argmaxinc/whisperkit-coreml/<name>`).
    func modelFolder(_ name: String) -> URL {
        paths.models
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(name)", isDirectory: true)
    }

    /// Whether a named model appears to be present on disk. Checks both the
    /// WhisperKit download layout and a bare `Models/<name>` folder.
    func isModelInstalled(_ name: String) -> Bool {
        let fm = FileManager.default
        let candidates = [modelFolder(name), paths.models.appendingPathComponent(name)]
        for url in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
               let contents = try? fm.contentsOfDirectory(atPath: url.path),
               !contents.isEmpty {
                return true
            }
        }
        return false
    }
}
