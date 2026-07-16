import Foundation
import CoreGraphics
import ApplicationServices

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyManager(_ m: HotkeyManager, didEmit gesture: HotkeyGesture)
}

/// Errors from `HotkeyManager.start()`.
enum HotkeyManagerError: Error, LocalizedError {
    case accessibilityNotTrusted
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required to detect the global hotkey. Grant it in System Settings › Privacy & Security › Accessibility, then restart Soro."
        case .tapCreationFailed:
            return "Failed to create the global keyboard event tap."
        }
    }
}

/// Global hotkey engine. Owns a `CGEventTap` on flagsChanged/keyDown/keyUp at
/// `cgSessionEventTap`, converts raw events into `HotkeyEvent`s, and feeds a pure
/// `HotkeyGestureRecognizer`. It re-enables the tap if the system disables it, and refuses
/// to start without Accessibility. All the tricky timing lives in the recognizer — the
/// manager is just plumbing (kept deliberately thin so the reviewable logic is testable).
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    /// Set by the coordinator; affects Esc + lock semantics (§2). The recognizer also tracks
    /// this internally, but we mirror it so the coordinator's view stays authoritative.
    var isRecordingActive: Bool = false {
        didSet { /* recognizer tracks its own state; nothing to push down */ }
    }

    private(set) var trigger: HotkeyData = .leftOption
    private(set) var pasteHotkey: HotkeyData?
    private(set) var handsFreeHotkey: HotkeyData?
    private(set) var commandHotkey: HotkeyData?

    private let recognizer: HotkeyGestureRecognizer
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingTimer: Timer?

    /// Tracks the current pressed-state of a modifier-only trigger so we can derive press/release
    /// from `flagsChanged` (which has no up/down of its own).
    private var triggerModifierDown = false

    init() {
        self.recognizer = HotkeyGestureRecognizer(config: HotkeyRecognizerConfig(trigger: .leftOption))
        self.recognizer.onGesture = { [weak self] gesture in
            guard let self else { return }
            self.delegate?.hotkeyManager(self, didEmit: gesture)
            self.reschedulePendingTimer()
        }
    }

    // MARK: - Lifecycle

    /// Whether the process currently holds Accessibility trust.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Fires the system Accessibility prompt (registers the app in the
    /// Privacy › Accessibility list and shows the "Open System Settings" button).
    /// Returns true if already trusted.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Creates the tap; throws `.accessibilityNotTrusted` if Accessibility isn't granted (checked
    /// via `AXIsProcessTrusted`), `.tapCreationFailed` if the tap can't be made.
    func start() throws {
        guard AXIsProcessTrusted() else { throw HotkeyManagerError.accessibilityNotTrusted }
        guard eventTap == nil else { return }   // already running

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,               // we observe; we never swallow the user's keys
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleTapCallback(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            throw HotkeyManagerError.tapCreationFailed
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        triggerModifierDown = false
    }

    /// Refreshes bindings from preferences (§6).
    func updateBindings(from prefs: Preferences) {
        trigger = prefs.hotkeyData
        handsFreeHotkey = prefs.handsFreeModeHotkeyDataArray.first
        pasteHotkey = prefs.pasteTranscriptHotkeyDataArray.first
        commandHotkey = prefs.commandModeHotkeyDataArray.first
        recognizer.updateConfig(HotkeyRecognizerConfig(trigger: trigger, pasteHotkey: pasteHotkey))
    }

    // MARK: - Tap callback

    private func handleTapCallback(type: CGEventType, event: CGEvent) {
        // The system may disable the tap under load / after a timeout — re-enable immediately or
        // dictation silently dies (Appendix C).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let time = event.timestamp > 0
            ? Double(event.timestamp) / 1_000_000_000.0   // mach-abs ns → s (monotonic)
            : ProcessInfo.processInfo.systemUptime

        let hkEvent: HotkeyEvent
        switch type {
        case .keyDown:
            hkEvent = HotkeyEvent(kind: .keyDown, keyCode: keyCode, modifiers: flags, isDown: true, timestamp: time)
        case .keyUp:
            hkEvent = HotkeyEvent(kind: .keyUp, keyCode: keyCode, modifiers: flags, isDown: false, timestamp: time)
        case .flagsChanged:
            // Derive press/release for the trigger modifier from whether its bit is now set.
            let isDown = Self.modifierBitSet(for: trigger, flags: event.flags)
            hkEvent = HotkeyEvent(kind: .flagsChanged, keyCode: keyCode, modifiers: flags, isDown: isDown, timestamp: time)
        default:
            return
        }

        // Recognizer callbacks hop to main so delegate work (coordinator) is main-actor safe.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recognizer.handle(hkEvent)
            // Some transitions enter a timed window WITHOUT emitting a gesture (a trigger-up
            // that starts the double-tap or triple-tap watch). The gesture-driven reschedule
            // wouldn't cover those, so reschedule after every handled event to guarantee a
            // timer exists for any pending window (lazy expiry on the next event still backs
            // this up).
            self.reschedulePendingTimer()
        }
    }

    /// Device-dependent (left/right-specific) modifier bits carried in the raw CGEventFlags.
    /// These distinguish the physical side, unlike the device-independent masks (`.maskAlternate`
    /// etc.) which are set when EITHER side of a pair is down. Values from IOKit's
    /// `NX_DEVICE*KEYMASK` constants.
    private enum DeviceFlag {
        static let leftShift: UInt64   = 0x0000_0002
        static let rightShift: UInt64  = 0x0000_0004
        static let leftControl: UInt64 = 0x0000_0001
        static let rightControl: UInt64 = 0x0000_2000
        static let leftAlt: UInt64     = 0x0000_0020
        static let rightAlt: UInt64    = 0x0000_0040
        static let leftCommand: UInt64 = 0x0000_0008
        static let rightCommand: UInt64 = 0x0000_0010
    }

    /// Whether the flag bit corresponding to `trigger` (a modifier-only key) is currently set.
    ///
    /// Uses the *device-dependent* (side-specific) bit for the exact physical key when present, so
    /// releasing the Left-Option trigger while Right Option is still held is correctly seen as a
    /// release. Falls back to the device-independent mask only if no side bit is set (some synthetic
    /// / remapped sources report only the generic mask) AND the generic mask is set — which for a
    /// keyCode-gated trigger still corresponds to that key's own change.
    static func modifierBitSet(for trigger: HotkeyData, flags: CGEventFlags) -> Bool {
        guard trigger.isModifierOnlyTrigger else { return false }
        let raw = flags.rawValue
        let deviceBit: UInt64
        let genericMask: CGEventFlags
        switch trigger.keyCode {
        case 58: deviceBit = DeviceFlag.leftAlt;      genericMask = .maskAlternate
        case 61: deviceBit = DeviceFlag.rightAlt;     genericMask = .maskAlternate
        case 55: deviceBit = DeviceFlag.leftCommand;  genericMask = .maskCommand
        case 54: deviceBit = DeviceFlag.rightCommand; genericMask = .maskCommand
        case 59: deviceBit = DeviceFlag.leftControl;  genericMask = .maskControl
        case 62: deviceBit = DeviceFlag.rightControl; genericMask = .maskControl
        case 56: deviceBit = DeviceFlag.leftShift;    genericMask = .maskShift
        case 60: deviceBit = DeviceFlag.rightShift;   genericMask = .maskShift
        default: deviceBit = DeviceFlag.leftAlt;      genericMask = .maskAlternate
        }
        // Prefer the side-specific bit. If the source populated ANY device bit for this modifier
        // pair, trust it exclusively (so the other side being down can't mask a release).
        let siblingBit = Self.siblingDeviceBit(for: deviceBit)
        if (raw & (deviceBit | siblingBit)) != 0 {
            return (raw & deviceBit) != 0
        }
        // No device bits at all → fall back to the generic mask (keyCode gating upstream ensures
        // this event is for our trigger key).
        return flags.contains(genericMask)
    }

    /// The paired (opposite-side) device bit for a given side-specific modifier bit.
    private static func siblingDeviceBit(for bit: UInt64) -> UInt64 {
        switch bit {
        case DeviceFlag.leftShift:    return DeviceFlag.rightShift
        case DeviceFlag.rightShift:   return DeviceFlag.leftShift
        case DeviceFlag.leftControl:  return DeviceFlag.rightControl
        case DeviceFlag.rightControl: return DeviceFlag.leftControl
        case DeviceFlag.leftAlt:      return DeviceFlag.rightAlt
        case DeviceFlag.rightAlt:     return DeviceFlag.leftAlt
        case DeviceFlag.leftCommand:  return DeviceFlag.rightCommand
        case DeviceFlag.rightCommand: return DeviceFlag.leftCommand
        default: return 0
        }
    }

    // MARK: - Pending double-tap timer

    /// Ensures a timer fires to expire a pending double-tap even if the user stops touching the
    /// keyboard. Recognizer also self-expires lazily on the next event, so this is belt-and-braces.
    private func reschedulePendingTimer() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        guard let expiry = recognizer.pendingExpiry else { return }
        let delay = max(0, expiry - ProcessInfo.processInfo.systemUptime)
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.recognizer.tick(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: - Test/coordinator seam

    /// Emits a gesture through the delegate (used by the coordinator to inject, and by tests).
    func emit(_ gesture: HotkeyGesture) {
        delegate?.hotkeyManager(self, didEmit: gesture)
    }
}
