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

    static let hidUsage: [UInt16: UInt16] = {
        // kVK_ANSI_* codes in HID order: A–Z, then 1–9, 0.
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        var map: [UInt16: UInt16] = [:]
        for (offset, code) in letters.enumerated() { map[UInt16(0x04 + offset)] = code }
        for (offset, code) in digits.enumerated() { map[UInt16(0x1E + offset)] = code }
        let named: [UInt16: UInt16] = [
            0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42, 0x33: 41,
            0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44, 0x39: 57,
            0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100, 0x42: 101, 0x43: 109,
            0x44: 103, 0x45: 111,
            0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
            0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
        ]
        map.merge(named) { $1 }
        return map
    }()
}
