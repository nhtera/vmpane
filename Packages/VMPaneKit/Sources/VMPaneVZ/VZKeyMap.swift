/// US keyboard layout: characters and USB HID keyboard usages → macOS virtual key codes, which
/// `VZVirtualMachineView` forwards to the guest as key presses.
public enum VZKeyMap {
    public struct Stroke: Equatable, Sendable {
        public let keyCode: UInt16
        public let shift: Bool
    }

    /// The key (and whether Shift is held) that types `character`, or nil for characters a US layout has no key for.
    public static func stroke(for character: Character) -> Stroke? {
        if let code = unshifted[character] { return Stroke(keyCode: code, shift: false) }
        if let code = shifted[character] { return Stroke(keyCode: code, shift: true) }
        if character.isLetter, character.isUppercase, let lower = character.lowercased().first, let code = unshifted[lower] {
            return Stroke(keyCode: code, shift: true)
        }
        return nil
    }

    /// macOS key code for a USB HID keyboard-page usage (0x04 = A …).
    public static func keyCode(forHIDUsage usage: UInt16) -> UInt16? { hidUsage[usage] }

    static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\r": 36, "\n": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50,
    ]

    static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29, "}": 30,
        "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50,
    ]

    /// Modifier key codes (for flagsChanged events).
    public static let shiftKeyCode: UInt16 = 56

    static let hidUsage: [UInt16: UInt16] = {
        var map: [UInt16: UInt16] = [:]
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for (offset, letter) in letters.enumerated() { map[UInt16(0x04 + offset)] = unshifted[letter] }
        let digits = Array("1234567890")
        for (offset, digit) in digits.enumerated() { map[UInt16(0x1E + offset)] = unshifted[digit] }
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
