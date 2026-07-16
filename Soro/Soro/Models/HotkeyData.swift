import Foundation

/// A hotkey binding, mirroring Willow's `hotkeyData` shape (brief §6).
/// The main trigger is *modifier-only* (e.g. Left Option, keyCode 58).
struct HotkeyData: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var keyName: String
    var isModifierOnlyTrigger: Bool
    var isRightModifier: Bool
    var additionalModifiers: [UInt16]
    var nonModifierKeys: [UInt16]
    var modifiers: UInt64
    var isMouseButton: Bool
    var mouseButton: Int

    init(keyCode: UInt16,
         keyName: String,
         isModifierOnlyTrigger: Bool,
         isRightModifier: Bool = false,
         additionalModifiers: [UInt16] = [],
         nonModifierKeys: [UInt16] = [],
         modifiers: UInt64 = 0,
         isMouseButton: Bool = false,
         mouseButton: Int = 0) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.isModifierOnlyTrigger = isModifierOnlyTrigger
        self.isRightModifier = isRightModifier
        self.additionalModifiers = additionalModifiers
        self.nonModifierKeys = nonModifierKeys
        self.modifiers = modifiers
        self.isMouseButton = isMouseButton
        self.mouseButton = mouseButton
    }

    /// Default main trigger: Left Option, modifier-only (brief §2/§6).
    static let leftOption = HotkeyData(
        keyCode: 58,
        keyName: "Left Option",
        isModifierOnlyTrigger: true
    )
}
