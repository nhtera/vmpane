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
