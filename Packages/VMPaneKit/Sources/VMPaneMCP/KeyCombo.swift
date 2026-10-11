import Foundation

/// `vm_key` combos ("cmd+shift+t", "ctrl+alt+delete", "enter", "f5") as USB HID usages (keyboard page), the way
/// `vm.input.key` takes keys: modifiers first, then the key.
enum KeyCombo {
    static let modifiers: [String: UInt16] = [
        "ctrl": 0xE0, "control": 0xE0, "shift": 0xE1, "alt": 0xE2, "option": 0xE2, "opt": 0xE2,
        "cmd": 0xE3, "command": 0xE3, "win": 0xE3, "windows": 0xE3, "meta": 0xE3, "super": 0xE3,
    ]

    static let keys: [String: UInt16] = {
        var keys: [String: UInt16] = [
            "enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
            "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37,
            "/": 0x38, "capslock": 0x39, "printscreen": 0x46, "insert": 0x49, "home": 0x4A, "pageup": 0x4B, "delete": 0x4C,
            "end": 0x4D, "pagedown": 0x4E, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        ]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { keys[String(letter)] = UInt16(0x04 + offset) }
        for (offset, digit) in "123456789".enumerated() { keys[String(digit)] = UInt16(0x1E + offset) }
        keys["0"] = 0x27
        for number in 1...12 { keys["f\(number)"] = UInt16(0x3A + number - 1) }
        return keys
    }()

    /// The usages to press in order (and release in reverse); nil for an unknown key.
    static func usages(_ combo: String) -> [UInt16]? {
        let parts = combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // "ctrl++" means ctrl and the plus key's base (=): the last empty part is "+".
        guard let last = parts.last else { return nil }
        let key = last.isEmpty && parts.count > 1 ? "=" : last
        var usages: [UInt16] = []
        for name in parts.dropLast() where !name.isEmpty {
            guard let usage = modifiers[name] else { return nil }
            usages.append(usage)
        }
        guard let usage = keys[key] ?? modifiers[key] else { return nil }
        return usages + [usage]
    }
}
