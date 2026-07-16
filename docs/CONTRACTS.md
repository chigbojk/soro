# Soro — Module Interface Contracts

All workers code against these signatures. Do not change a signature without updating this file in
the same commit. App target: **Soro**, bundle id `com.jordanchigbo.soro`, macOS 14+, Swift 6
(`@MainActor` UI, actors/`Sendable` where noted). Data dir:
`~/Library/Application Support/com.jordanchigbo.soro/` (see brief §6 for schemas).

## Project layout

```
Soro/                      # Xcode project root (Soro.xcodeproj)
  Soro/
    App/            SoroApp.swift, AppState.swift, MenuBarMenu.swift
    Core/
      Audio/        AudioCaptureService.swift, RecordingWriter.swift
      Transcription/TranscriptionService.swift, ModelManager.swift
      Cleanup/      CleanupService.swift, OllamaClient.swift, PromptBuilder.swift, ContextDetector.swift
      Insertion/    InsertionService.swift
      Hotkey/       HotkeyManager.swift, HotkeyGesture.swift
      Pipeline/     DictationCoordinator.swift
    Stores/         PreferencesStore.swift, TranscriptStore.swift, GlossaryStore.swift,
                    PersonalizationStore.swift, StatsStore.swift, AutoDictionaryStore.swift
    Models/         Transcript.swift, GlossaryEntry.swift, HotkeyData.swift, Preferences.swift,
                    PersonalizationPreferences.swift, UsageStats.swift
    UI/
      Bar/          RecordingBarPanel.swift, RecordingBarView.swift, WaveformView.swift
      Dashboard/    DashboardWindow.swift, HomeView.swift, DictionaryView.swift,
                    StyleMatchingView.swift, SettingsView.swift
      Onboarding/   OnboardingView.swift
    Resources/      sounds, Assets.xcassets
  docs/             this file, brief
```

## Data models (Codable, mirror brief §6 JSON keys exactly)

```swift
struct Transcript: Codable, Identifiable, Sendable {
    let id: UUID
    var text: String                  // "ERROR_TRANSCRIBING" sentinel on failure
    var audioURL: URL?                // nil when privacy mode deleted the audio
    var recordingDuration: TimeInterval
    var date: Double                  // Cocoa epoch: Date.timeIntervalSinceReferenceDate
}

struct GlossaryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    var term: String
    var tag: String                   // "My Terms" | "Auto-Learned"
    var isEnabled: Bool
    var isReplacement: Bool
    var replacement: String?          // present when isReplacement == true
}

struct HotkeyData: Codable, Equatable, Sendable {
    var keyCode: UInt16; var keyName: String
    var isModifierOnlyTrigger: Bool; var isRightModifier: Bool
    var additionalModifiers: [UInt16]; var nonModifierKeys: [UInt16]
    var modifiers: UInt64; var isMouseButton: Bool; var mouseButton: Int
}

struct Preferences: Codable { /* keys per brief §6 preferences.json; defaults per brief */ }
struct PersonalizationPreferences: Codable { /* per brief §6 */ }
struct UsageStats: Codable {
    var lifetimeDictations: Int; var lifetimeScribeUses: Int
    var handsFreeEverUsed: Bool; var barEverMoved: Bool
}

enum DictationContext: String, Codable, Sendable { case casual, email, work, other }
```

## Core service protocols

```swift
// Audio — AVAudioEngine, 16kHz mono Float32
protocol AudioCaptureService: AnyObject {
    var levelStream: AsyncStream<Float> { get }        // 0…1 mic level for waveform, ~30Hz
    func start() throws                                 // begins capture + buffering
    func stop() async -> CapturedAudio                  // returns full buffer + saved file
    func cancel()                                       // discard, delete partial file
}
struct CapturedAudio: Sendable {
    let samples: [Float]              // 16kHz mono
    let duration: TimeInterval
    let fileURL: URL?                 // wav/opus on disk (nil if save failed)
}

// Transcription — WhisperKit preferred (App A)
protocol TranscriptionService: AnyObject {
    var isModelReady: Bool { get }
    func prepareModel(_ name: String, progress: @escaping (Double) -> Void) async throws
    func transcribe(_ audio: CapturedAudio, language: String?, initialPrompt: String?) async throws -> String
}

// Cleanup — Ollama; NEVER throws to caller: falls back to input text
protocol CleanupService: AnyObject {
    func isAvailable() async -> Bool
    /// Returns (text, wasCleaned). timeout ~4s → (input, false).
    func cleanup(_ raw: String, context: CleanupContext) async -> (text: String, wasCleaned: Bool)
}
struct CleanupContext: Sendable {
    let appName: String; let bundleId: String
    let context: DictationContext
    let messagingStyle: String; let scribeStyle: String; let personalTweak: String
    let glossaryTerms: [String]
    let styleSamples: [String]        // 0–3 recent accepted outputs
    let isCodeEditor: Bool
}

// Insertion — pasteboard ⌘V with restore; typing fallback
protocol InsertionService: AnyObject {
    @discardableResult func insert(_ text: String) async -> InsertionResult
    func reinsertLast() async -> InsertionResult
}
enum InsertionResult: Sendable { case pasted, typed, failedSecureInput, failed }

// Hotkey — CGEventTap; emits gestures, owns no business logic
enum HotkeyGesture: Sendable {
    case pushToTalkBegan, pushToTalkEnded
    case lockToggledOn, lockToggledOff
    case cancel                       // Esc while recording
    case pasteLastTranscript
}
protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyManager(_ m: HotkeyManager, didEmit gesture: HotkeyGesture)
}
final class HotkeyManager {           // concrete; the state machine under adversarial review
    weak var delegate: HotkeyManagerDelegate?
    var isRecordingActive: Bool       // set by coordinator; affects Esc + lock semantics
    func start() throws               // creates tap; throws if no Accessibility
    func stop()
    func updateBindings(from prefs: Preferences)
}

// Pipeline — the only component that touches everything
@MainActor final class DictationCoordinator: ObservableObject {
    @Published var state: DictationState
    func beginRecording(locked: Bool)
    func endRecording()               // stop → transcribe → glossary → cleanup → insert → persist
    func cancelRecording()
    func pasteLast()
}
enum DictationState: Equatable { case idle, recording(locked: Bool), transcribing, inserting, done, error(String) }
```

## Stores (all JSON-file-backed, @MainActor ObservableObject)

```swift
final class PreferencesStore: ObservableObject   { @Published var prefs: Preferences; func save() }
final class TranscriptStore: ObservableObject {
    func add(_ t: Transcript); func delete(id: UUID)
    func recent(limit: Int, offset: Int) -> [Transcript]
    func search(_ q: String, limit: Int) -> [Transcript]   // must handle ~10k files: lazy index
    var lastTranscript: Transcript? { get }
}
final class GlossaryStore: ObservableObject       { @Published var entries: [GlossaryEntry]; CRUD; func enabledTerms() -> [String]; func applyReplacements(to: String) -> String }
final class PersonalizationStore: ObservableObject { @Published var prefs: PersonalizationPreferences; func save(); func styleFor(_ ctx: DictationContext) -> (messaging: String, scribe: String, tweak: String) }
final class StatsStore: ObservableObject          { @Published var stats: UsageStats; func recordDictation(words: Int, duration: TimeInterval); derived: dictatedWords, avgWPM, timeSavedSeconds, dayStreak }
final class AutoDictionaryStore: ObservableObject { func observe(transcript: String); func suggestions() -> [String]; func dismiss(_ word: String) }
```

## UI contracts

- `RecordingBarPanel`: non-activating floating `NSPanel` hosting `RecordingBarView(coordinator:)`;
  observes `DictationCoordinator.state` + `AudioCaptureService.levelStream`. Draggable; persists frame
  to prefs. Never steals focus.
- Dashboard views each take exactly the stores they need via `@EnvironmentObject`:
  `HomeView` (TranscriptStore, StatsStore, PreferencesStore), `DictionaryView` (GlossaryStore,
  AutoDictionaryStore), `StyleMatchingView` (PersonalizationStore), `SettingsView`
  (PreferencesStore + model/ollama pickers via injected services).
- `AppState` composes everything, owns service instances, wires HotkeyManager → DictationCoordinator.

## Cross-cutting rules

- No network calls except `http://127.0.0.1:11434`. No telemetry.
- Every failure path degrades to something useful (raw text, sentinel transcript record) — never a
  silent no-op, never a hang.
- Context (frontmost app) is captured at **record start** by `ContextDetector.snapshot()`.
- All file writes atomic (`.atomic` or temp+rename).
