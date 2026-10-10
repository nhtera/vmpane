/// Keyboard keys shared by every backend: USB HID keyboard-page usages (what the control protocol sends),
/// their names (QEMU's QKeyCode names), and the US-layout key that types each character. Backends map
/// usages to their own codes (VZ: macOS key codes; QEMU: these names).
public enum KeyNames {
    public struct Stroke: Equatable, Sendable {
        public let usage: UInt16
        public let shift: Bool

        public init(usage: UInt16, shift: Bool) {
            self.usage = usage
            self.shift = shift
        }
    }

    public static let leftShift: UInt16 = 0xE1

    /// The key (and whether Shift is held) that types `character` on a US layout, or nil when there is none.
    public static func stroke(for character: Character) -> Stroke? {
        if let usage = unshifted[character] { return Stroke(usage: usage, shift: false) }
        if let usage = shifted[character] { return Stroke(usage: usage, shift: true) }
        if character.isASCII, character.isUppercase, let lower = character.lowercased().first, let usage = unshifted[lower] {
            return Stroke(usage: usage, shift: true)
        }
        return nil
    }

    public static func name(forHIDUsage usage: UInt16) -> String? { names[usage] }

    /// HID usage → QKeyCode name.
    public static let names: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[UInt16(0x04 + offset)] = String(letter) }
        for (offset, digit) in "1234567890".enumerated() { map[UInt16(0x1E + offset)] = String(digit) }
        for number in 1...12 { map[UInt16(0x3A + number - 1)] = "f\(number)" }
        for number in 13...24 { map[UInt16(0x68 + number - 13)] = "f\(number)" }
        for number in 1...9 { map[UInt16(0x59 + number - 1)] = "kp_\(number)" }
        let named: [UInt16: String] = [
            0x28: "ret", 0x29: "esc", 0x2A: "backspace", 0x2B: "tab", 0x2C: "spc", 0x2D: "minus", 0x2E: "equal",
            0x2F: "bracket_left", 0x30: "bracket_right", 0x31: "backslash", 0x33: "semicolon", 0x34: "apostrophe",
            0x35: "grave_accent", 0x36: "comma", 0x37: "dot", 0x38: "slash", 0x39: "caps_lock",
            0x46: "print", 0x47: "scroll_lock", 0x48: "pause", 0x49: "insert", 0x4A: "home", 0x4B: "pgup", 0x4C: "delete",
            0x4D: "end", 0x4E: "pgdn", 0x4F: "right", 0x50: "left", 0x51: "down", 0x52: "up",
            0x53: "num_lock", 0x54: "kp_divide", 0x55: "kp_multiply", 0x56: "kp_subtract", 0x57: "kp_add", 0x58: "kp_enter",
            0x62: "kp_0", 0x63: "kp_decimal", 0x64: "less", 0x65: "compose", 0x67: "kp_equals",
            0x7F: "audiomute", 0x80: "volumeup", 0x81: "volumedown", 0x85: "kp_comma",
            0x87: "ro", 0x88: "katakanahiragana", 0x89: "yen", 0x8A: "henkan", 0x8B: "muhenkan", 0x90: "lang1", 0x91: "lang2",
            0xE0: "ctrl", 0xE1: "shift", 0xE2: "alt", 0xE3: "meta_l", 0xE4: "ctrl_r", 0xE5: "shift_r", 0xE6: "alt_r", 0xE7: "meta_r",
        ]
        map.merge(named) { $1 }
        return map
    }()

    /// macOS virtual key code (`NSEvent.keyCode`, `kVK_*`) for a HID usage: what the VZ view expects for
    /// synthetic input, and (reversed) how the SPICE display maps a real key press to a usage.
    public static let macKeyCodes: [UInt16: UInt16] = {
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
            0x44: 103, 0x45: 111, 0x68: 105, 0x69: 107, 0x6A: 113, 0x6B: 106, 0x6C: 64, 0x6D: 79, 0x6E: 80, 0x6F: 90,
            0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
            // Keypad (Clear is where PC keyboards have Num Lock).
            0x53: 71, 0x54: 75, 0x55: 67, 0x56: 78, 0x57: 69, 0x58: 76, 0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87,
            0x5E: 88, 0x5F: 89, 0x60: 91, 0x61: 92, 0x62: 82, 0x63: 65, 0x67: 81,
            // ISO section key, JIS keys, media keys.
            0x64: 10, 0x87: 94, 0x89: 93, 0x90: 104, 0x91: 102, 0x7F: 74, 0x80: 72, 0x81: 73,
            0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
        ]
        map.merge(named) { $1 }
        return map
    }()

    /// The HID usage of a macOS virtual key code, or nil for keys with no PC equivalent (Fn).
    public static func hidUsage(forMacKeyCode code: UInt16) -> UInt16? { usagesByMacKeyCode[code] }

    private static let usagesByMacKeyCode: [UInt16: UInt16] = Dictionary(
        macKeyCodes.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    static let unshifted: [Character: UInt16] = {
        var map: [Character: UInt16] = [:]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[letter] = UInt16(0x04 + offset) }
        for (offset, digit) in "1234567890".enumerated() { map[digit] = UInt16(0x1E + offset) }
        let named: [Character: UInt16] = [
            "\r": 0x28, "\n": 0x28, "\t": 0x2B, " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33,
            "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
        ]
        map.merge(named) { $1 }
        return map
    }()

    static let shifted: [Character: UInt16] = [
        "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
        "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
    ]
}
