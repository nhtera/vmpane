import Foundation
import VMPaneCore

public enum QEMUInputError: Error, Equatable, Sendable {
    case unmappedKey(UInt16)
    case unmappedCharacter(Character)
}

/// Synthetic input as QMP commands (`input-send-event`, `send-key`) for the USB keyboard and tablet. Works
/// without a display client and without macOS input permissions.
enum QEMUInput {
    /// One QMP command, or a pause between commands.
    enum Step: Equatable {
        case command(String, [String: JSONValue])
        case pause(Duration)
    }

    /// Absolute pointer axes run 0…32767 across the guest display.
    static let axisMax = 32767
    /// Typing: each key is held briefly, then a gap. Faster injection makes Windows under load repeat keys (S2).
    static let keyHold = 30
    static let keyGap = Duration.milliseconds(100)
    /// Pixels of scroll per wheel notch.
    static let pixelsPerNotch = 40.0

    enum Button: String, CaseIterable {
        case left, right, middle

        /// Bit in `InputEvent.pointer`'s button mask.
        var mask: Int {
            switch self {
            case .left: 1
            case .right: 2
            case .middle: 4
            }
        }
    }

    /// The steps for `event`. `display` is the guest display size in pixels (pointer coordinates are in it);
    /// `pressed` is the button mask currently held, updated for pointer events.
    static func steps(for event: InputEvent, display: (width: Int, height: Int), pressed: inout Int) throws -> [Step] {
        switch event {
        case .key(let usage, let down):
            guard let name = KeyNames.name(forHIDUsage: usage) else { throw QEMUInputError.unmappedKey(usage) }
            return [.command("input-send-event", ["events": [keyEvent(name, down: down)]])]
        case .text(let text):
            var steps: [Step] = []
            for character in text {
                guard let stroke = KeyNames.stroke(for: character), let name = KeyNames.name(forHIDUsage: stroke.usage) else {
                    throw QEMUInputError.unmappedCharacter(character)
                }
                let keys: [JSONValue] = (stroke.shift ? ["shift"] : []).map(qcode) + [qcode(name)]
                steps += [.command("send-key", ["keys": .array(keys), "hold-time": .int(Int64(keyHold))]), .pause(keyGap)]
            }
            return steps
        case .pointer(let x, let y, let buttons):
            var events: [JSONValue] = [
                axis("x", x, extent: display.width), axis("y", y, extent: display.height),
            ]
            for button in Button.allCases where (buttons & button.mask) != (pressed & button.mask) {
                events.append(["type": "btn", "data": ["button": .string(button.rawValue), "down": .bool(buttons & button.mask != 0)]])
            }
            pressed = buttons & Button.allCases.reduce(0) { $0 | $1.mask }
            return [.command("input-send-event", ["events": .array(events)])]
        case .scroll(let dx, let dy):
            return wheel(dy, negative: "wheel-up", positive: "wheel-down") + wheel(dx, negative: "wheel-left", positive: "wheel-right")
        }
    }

    private static func qcode(_ name: String) -> JSONValue { ["type": "qcode", "data": .string(name)] }

    private static func keyEvent(_ name: String, down: Bool) -> JSONValue {
        ["type": "key", "data": ["down": .bool(down), "key": qcode(name)]]
    }

    private static func axis(_ axis: String, _ value: Double, extent: Int) -> JSONValue {
        let scaled = extent > 1 ? (value / Double(extent - 1)) * Double(axisMax) : 0
        let clamped = Int64(min(max(scaled.rounded(), 0), Double(axisMax)))
        return ["type": "abs", "data": ["axis": .string(axis), "value": .int(clamped)]]
    }

    /// Wheel notches for a scroll distance in pixels (negative = up/left), at least one for any movement.
    private static func wheel(_ delta: Double, negative: String, positive: String) -> [Step] {
        guard delta != 0 else { return [] }
        let notches = max(1, Int((abs(delta) / pixelsPerNotch).rounded()))
        let button = JSONValue.string(delta < 0 ? negative : positive)
        let click: [JSONValue] = [
            ["type": "btn", "data": ["button": button, "down": true]], ["type": "btn", "data": ["button": button, "down": false]],
        ]
        return Array(repeating: .command("input-send-event", ["events": .array(click)]), count: notches)
    }
}
