import VMPaneCore

/// USB HID keyboard usages → macOS virtual key codes, which `VZVirtualMachineView` forwards to the guest as
/// key presses. Characters go through the shared US layout (`KeyNames`).
public enum VZKeyMap {
    public struct Stroke: Equatable, Sendable {
        public let keyCode: UInt16
        public let shift: Bool
    }

    /// The key (and whether Shift is held) that types `character`, or nil for characters a US layout has no key for.
    public static func stroke(for character: Character) -> Stroke? {
        guard let stroke = KeyNames.stroke(for: character), let code = hidUsage[stroke.usage] else { return nil }
        return Stroke(keyCode: code, shift: stroke.shift)
    }

    /// macOS key code for a USB HID keyboard-page usage (0x04 = A …).
    public static func keyCode(forHIDUsage usage: UInt16) -> UInt16? { hidUsage[usage] }

    /// Modifier key codes (for flagsChanged events).
    public static let shiftKeyCode: UInt16 = 56

    static var hidUsage: [UInt16: UInt16] { KeyNames.macKeyCodes }
}
