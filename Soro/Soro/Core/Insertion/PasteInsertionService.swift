import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Real text-insertion implementation (brief §3e, App C), replacing `StubInsertionService`.
///
/// Primary path: stash the full pasteboard, place `text`, synthesize ⌘V via `CGEvent`, wait
/// briefly, then restore the original pasteboard. Fallback: type the characters directly with
/// `CGEvent` Unicode keystrokes. If macOS reports secure input is active (a password field owns
/// the keyboard), short-circuit to `.failedSecureInput` without touching the pasteboard.
///
/// Decoupled by design: configuration (trailing-Return, per-app lowercasing) is injected via
/// closures so the service never imports a store. Every failure path degrades gracefully and
/// never hangs.
final class PasteInsertionService: InsertionService {

    // MARK: - Injected configuration

    /// Whether to press Return after a successful insert (Preferences.cursorAutomaticEnter).
    private let automaticEnter: () -> Bool
    /// Bundle id of the frontmost app at insertion time (for per-app rules). Defaults to the
    /// system frontmost app; injectable for tests.
    private let frontmostBundleID: () -> String?
    /// Whether secure input is currently enabled. Injectable so tests can exercise the
    /// short-circuit without a real password field. Defaults to the live system flag.
    private let secureInputEnabled: () -> Bool
    /// Milliseconds to wait after ⌘V before restoring the pasteboard.
    private let pasteSettleMillis: UInt64
    /// The pasteboard to operate on. Defaults to `.general`; injectable for tests.
    private let pasteboard: NSPasteboard
    /// When false, the CGEvent posting steps are skipped (used by tests to exercise the
    /// pasteboard save/restore + bookkeeping logic without synthesizing real key events).
    private let postsEvents: Bool

    // MARK: - State

    /// Last text handed to `insert` (for `reinsertLast`). Guarded by `MainActor` hops.
    private var lastInserted: String?

    init(
        automaticEnter: @escaping () -> Bool = { false },
        frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        secureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        pasteSettleMillis: UInt64 = 150,
        pasteboard: NSPasteboard = .general,
        postsEvents: Bool = true
    ) {
        self.automaticEnter = automaticEnter
        self.frontmostBundleID = frontmostBundleID
        self.secureInputEnabled = secureInputEnabled
        self.pasteSettleMillis = pasteSettleMillis
        self.pasteboard = pasteboard
        self.postsEvents = postsEvents
    }

    // MARK: - InsertionService

    @discardableResult
    func insert(_ text: String) async -> InsertionResult {
        guard !secureInputEnabled() else { return .failedSecureInput }

        let prepared = applyPerAppRules(to: text)
        // Record what we intended to insert regardless of transport success, so `reinsertLast`
        // reflects the user's most recent dictation.
        lastInserted = prepared

        // Empty string: nothing to place, but not a failure.
        guard !prepared.isEmpty else { return .pasted }

        if let result = await pasteViaPasteboard(prepared) {
            if automaticEnter() { pressReturn() }
            return result
        }

        // Pasteboard path failed — fall back to direct typing.
        if typeDirectly(prepared) {
            if automaticEnter() { pressReturn() }
            return .typed
        }

        return .failed
    }

    func reinsertLast() async -> InsertionResult {
        guard let text = lastInserted else { return .failed }
        // Re-run through the full insert path (re-checks secure input, per-app rules, etc.).
        return await insert(text)
    }

    // MARK: - Pasteboard path

    /// Saves the full pasteboard, writes `text`, sends ⌘V, waits, then restores. Returns
    /// `.pasted` on success, or `nil` if the pasteboard couldn't be written (caller falls back).
    private func pasteViaPasteboard(_ text: String) async -> InsertionResult? {
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return nil
        }

        guard postsEvents else {
            // Test mode: we validated the round-trip; report success without posting keys.
            return .pasted
        }

        sendCommandV()
        // Let the target app read the pasteboard before we restore it.
        try? await Task.sleep(nanoseconds: pasteSettleMillis * 1_000_000)
        return .pasted
    }

    /// Snapshot of every item on the pasteboard: for each item, all types with their raw data.
    private struct SavedItem { let entries: [(NSPasteboard.PasteboardType, Data)] }

    private func savePasteboard() -> [SavedItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let entries: [(NSPasteboard.PasteboardType, Data)] = item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return SavedItem(entries: entries)
        }
    }

    private func restorePasteboard(_ saved: [SavedItem]) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let newItems: [NSPasteboardItem] = saved.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved.entries {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(newItems)
    }

    // MARK: - CGEvent synthesis

    private func sendCommandV() {
        postKeyChord(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    private func pressReturn() {
        postKeyChord(keyCode: CGKeyCode(kVK_Return), flags: [])
    }

    /// Posts a key-down then key-up for `keyCode` with the given modifier `flags`.
    private func postKeyChord(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard postsEvents else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Types `text` by posting Unicode keyboard events in chunks (fallback when paste fails).
    /// Returns true if events were dispatched; false if CGEvent creation failed outright.
    @discardableResult
    private func typeDirectly(_ text: String) -> Bool {
        guard postsEvents else { return true }
        let source = CGEventSource(stateID: .combinedSessionState)
        let scalars = Array(text.utf16)
        guard !scalars.isEmpty else { return true }

        // CGEvent keyboard Unicode payloads are bounded; chunk to be safe.
        let chunkSize = 20
        var index = 0
        var anyPosted = false
        while index < scalars.count {
            let end = min(index + chunkSize, scalars.count)
            let chunk = Array(scalars[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return anyPosted }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            anyPosted = true
            index = end
        }
        return anyPosted
    }

    // MARK: - Per-app rules

    /// Minimal per-app tweaks (brief §3e). Currently: lowercase leading text in Messages.
    /// Kept intentionally small.
    private func applyPerAppRules(to text: String) -> String {
        guard let bundle = frontmostBundleID() else { return text }
        if bundle == "com.apple.MobileSMS" {
            return text.lowercasedFirstCharacter()
        }
        return text
    }
}

private extension String {
    /// Lowercases only the first character, leaving the rest untouched.
    func lowercasedFirstCharacter() -> String {
        guard let first = first else { return self }
        return first.lowercased() + dropFirst()
    }
}
