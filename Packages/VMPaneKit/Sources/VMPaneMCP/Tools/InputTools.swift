import Foundation
import VMPaneControl
import VMPaneCore

/// Mouse and keyboard. Coordinates are pixels of the last vm_screenshot (scaled to the VM's own); each tool can
/// wait (`settle_ms`) and return a fresh screenshot (`screenshot_after`).
enum InputTools {
    static let writes: JSONValue = ["destructiveHint": false, "openWorldHint": false]

    static func all(_ access: VMAccess) -> [Tool] {
        [click(access), move(access), drag(access), scroll(access), type(access), key(access)]
    }

    static let after: [String: JSONValue] = [
        "settle_ms": Schema.integer("Wait this long afterwards (default 300).", minimum: 0, maximum: 10000),
        "screenshot_after": Schema.boolean("Return a screenshot afterwards."),
    ]

    static func point(_ name: String) -> JSONValue {
        Schema.object(
            ["x": Schema.number("\(name) x, in screenshot pixels."), "y": Schema.number("\(name) y, in screenshot pixels.")],
            required: ["x", "y"])
    }

    /// Guest pixels for screenshot pixels.
    static func guest(_ access: VMAccess, _ vm: String, _ x: Double?, _ y: Double?) async throws -> (Double, Double) {
        guard let x, let y else { throw ToolFailure("x and y are required") }
        let scale = try await access.scale(for: vm)
        return (x * scale, y * scale)
    }

    static func pointer(_ access: VMAccess, _ vm: String, _ point: (Double, Double), buttons: Int) async throws {
        _ = try await access.call(vm, .vmInputPointer, ["x": .double(point.0), "y": .double(point.1), "buttons": .int(Int64(buttons))])
    }

    /// Settles, then the result (with a screenshot when asked).
    static func finish(_ access: VMAccess, _ vm: String, _ args: JSONValue, _ text: String) async throws -> ToolResult {
        try await Task.sleep(for: .milliseconds(args["settle_ms"]?.intValue ?? 300))
        guard args["screenshot_after"] == true else { return ToolResult(text: text) }
        var shot = try await VMTools.screenshot(access).handler(["vm": .string(vm)], ToolContext(client: nil) { _, _, _ in })
        shot.content.insert(["type": "text", "text": .string(text)], at: 0)
        return shot
    }

    static func click(_ access: VMAccess) -> Tool {
        var properties: [String: JSONValue] = [
            "vm": Schema.vm, "x": Schema.number("x in screenshot pixels."), "y": Schema.number("y in screenshot pixels."),
            "button": Schema.string("Which button (default left).", enum: ["left", "right", "middle"]),
            "count": Schema.integer("Clicks (2 for a double click).", minimum: 1, maximum: 3),
        ]
        properties.merge(after) { $1 }
        return Tool(
            "vm_click", "Click at a point of the screen.", schema: Schema.object(properties, required: ["vm", "x", "y"]),
            annotations: writes
        ) { args, _ in
            let vm = try args.string("vm")
            let target = try await guest(access, vm, args["x"]?.doubleValue, args["y"]?.doubleValue)
            let bit = ["left": 1, "right": 2, "middle": 4][args["button"]?.stringValue ?? "left"] ?? 1
            try await pointer(access, vm, target, buttons: 0)
            for _ in 0..<max(1, Int(args["count"]?.intValue ?? 1)) {
                try await pointer(access, vm, target, buttons: bit)
                try await Task.sleep(for: .milliseconds(40))
                try await pointer(access, vm, target, buttons: 0)
                try await Task.sleep(for: .milliseconds(60))
            }
            return try await finish(access, vm, args, "clicked")
        }
    }

    static func move(_ access: VMAccess) -> Tool {
        var properties: [String: JSONValue] = [
            "vm": Schema.vm, "x": Schema.number("x in screenshot pixels."), "y": Schema.number("y in screenshot pixels."),
        ]
        properties.merge(after) { $1 }
        return Tool(
            "vm_move", "Move the pointer (hover).", schema: Schema.object(properties, required: ["vm", "x", "y"]), annotations: writes
        ) { args, _ in
            let vm = try args.string("vm")
            try await pointer(access, vm, try await guest(access, vm, args["x"]?.doubleValue, args["y"]?.doubleValue), buttons: 0)
            return try await finish(access, vm, args, "moved")
        }
    }

    static func drag(_ access: VMAccess) -> Tool {
        var properties: [String: JSONValue] = ["vm": Schema.vm, "from": point("Start"), "to": point("End")]
        properties.merge(after) { $1 }
        return Tool(
            "vm_drag", "Drag with the left button from one point to another.",
            schema: Schema.object(properties, required: ["vm", "from", "to"]),
            annotations: writes
        ) { args, _ in
            let vm = try args.string("vm")
            let from = try await guest(access, vm, args["from"]?["x"]?.doubleValue, args["from"]?["y"]?.doubleValue)
            let to = try await guest(access, vm, args["to"]?["x"]?.doubleValue, args["to"]?["y"]?.doubleValue)
            try await pointer(access, vm, from, buttons: 0)
            try await pointer(access, vm, from, buttons: 1)
            for step in 1...10 {
                let fraction = Double(step) / 10
                try await pointer(access, vm, (from.0 + (to.0 - from.0) * fraction, from.1 + (to.1 - from.1) * fraction), buttons: 1)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await pointer(access, vm, to, buttons: 0)
            return try await finish(access, vm, args, "dragged")
        }
    }

    static func scroll(_ access: VMAccess) -> Tool {
        var properties: [String: JSONValue] = [
            "vm": Schema.vm, "dx": Schema.number("Right is positive (pixels)."), "dy": Schema.number("Down is positive (pixels)."),
        ]
        properties.merge(after) { $1 }
        let schema = Schema.object(properties, required: ["vm"])
        return Tool("vm_scroll", "Scroll where the pointer is.", schema: schema, annotations: writes) { args, _ in
            let vm = try args.string("vm")
            _ = try await access.call(
                vm, .vmInputScroll, ["dx": .double(args["dx"]?.doubleValue ?? 0), "dy": .double(-(args["dy"]?.doubleValue ?? 0))])
            return try await finish(access, vm, args, "scrolled")
        }
    }

    static func type(_ access: VMAccess) -> Tool {
        var properties: [String: JSONValue] = ["vm": Schema.vm, "text": Schema.string("What to type (US keyboard layout).")]
        properties.merge(after) { $1 }
        let schema = Schema.object(properties, required: ["vm", "text"])
        return Tool("vm_type", "Type text into the VM.", schema: schema, annotations: writes) { args, _ in
            let vm = try args.string("vm")
            _ = try await access.call(vm, .vmInputText, ["text": .string(try args.string("text"))])
            return try await finish(access, vm, args, "typed")
        }
    }

    static func key(_ access: VMAccess) -> Tool {
        var properties: [String: JSONValue] = [
            "vm": Schema.vm, "combo": Schema.string("A key or combination: enter, esc, f5, cmd+c, ctrl+alt+delete, shift+tab, up…"),
        ]
        properties.merge(after) { $1 }
        return Tool(
            "vm_key", "Press a key or a key combination.", schema: Schema.object(properties, required: ["vm", "combo"]), annotations: writes
        ) { args, _ in
            let vm = try args.string("vm")
            let combo = try args.string("combo")
            guard let usages = KeyCombo.usages(combo) else { throw ToolFailure("unknown key in \(combo.debugDescription)") }
            for usage in usages { _ = try await access.call(vm, .vmInputKey, ["usage": .int(Int64(usage)), "down": true]) }
            for usage in usages.reversed() { _ = try await access.call(vm, .vmInputKey, ["usage": .int(Int64(usage)), "down": false]) }
            return try await finish(access, vm, args, "pressed \(combo)")
        }
    }
}
