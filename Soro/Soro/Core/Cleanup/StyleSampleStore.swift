import Foundation

/// A single accepted-output sample, keyed per context, used as a tone anchor for
/// the cleanup prompt (brief §5A "Adaptive style memory").
struct StyleSample: Codable, Equatable, Sendable {
    var text: String
    var date: Double   // Cocoa epoch: Date.timeIntervalSinceReferenceDate
}

/// Lightweight per-context ring buffer of the user's *accepted* cleanup outputs
/// (brief §5A). No training — just a small rolling sample fed back into the
/// prompt as few-shot style anchors so tone drifts toward how the user writes.
///
/// Persists to `Preferences/style_samples.json` as `{ context: [StyleSample] }`.
/// Keeps at most `capacity` (5) samples per context; `recent(_:)` returns the
/// newest N (default 3, matching the prompt's 0–3 tone anchors).
final class StyleSampleStore {
    /// Max samples retained per context.
    let capacity: Int

    private let paths: AppPaths
    private var samples: [String: [StyleSample]]
    private let lock = NSLock()

    /// File location, derived from `AppPaths` without editing that type (owned by
    /// M1): `Preferences/style_samples.json`.
    private var fileURL: URL {
        paths.preferences.appendingPathComponent("style_samples.json")
    }

    init(paths: AppPaths = .live, capacity: Int = 5) {
        self.paths = paths
        self.capacity = capacity
        self.samples = JSONFile.read([String: [StyleSample]].self, from: paths.preferences.appendingPathComponent("style_samples.json")) ?? [:]
    }

    /// Records an accepted output for a context, trimming to the newest
    /// `capacity` samples. Blank text is ignored.
    func append(_ text: String, for context: DictationContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        var list = samples[context.rawValue] ?? []
        list.append(StyleSample(text: trimmed, date: Date().timeIntervalSinceReferenceDate))
        if list.count > capacity {
            list.removeFirst(list.count - capacity)
        }
        samples[context.rawValue] = list
        let snapshot = samples
        lock.unlock()

        try? JSONFile.write(snapshot, to: fileURL)
    }

    /// The newest `count` samples (default 3) for a context, oldest-first, as
    /// plain strings ready to feed into the prompt's tone-anchor block.
    func recent(_ count: Int = 3, for context: DictationContext) -> [String] {
        lock.lock()
        let list = samples[context.rawValue] ?? []
        lock.unlock()
        return list.suffix(max(0, count)).map(\.text)
    }
}
