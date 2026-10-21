import Foundation
import VMPaneControl
import VMPaneCore

/// Mouse and keyboard. Coordinates are pixels of the last vm_screenshot (scaled to the VM's own). Every tool runs as
/// one `vm.input.batch` (vm_actions as many actions, the others as one), which says afterwards whether the screen
/// changed (`verified`); `screenshot_after` adds a screenshot.
enum InputTools {
    static let writes: JSONValue = ["destructiveHint": false, "openWorldHint": false]

    static func all(_ access: VMAccess) -> [Tool] {
        [actions(access), click(access), move(access), drag(access), scroll(access), type(access), key(access)]
    }

    static let after: [String: JSONValue] = [
        "settle_ms": Schema.integer(
            "Wait up to this long for the screen to settle (default 300); a change returns as soon as it holds still.", minimum: 0,
            maximum: 10000),
        "screenshot_after": Schema.boolean("Return a screenshot afterwards."),
    ]

    static func point(_ name: String) -> JSONValue {
        Schema.object(
            ["x": Schema.number("\(name) x, in screenshot pixels."), "y": Schema.number("\(name) y, in screenshot pixels.")],
            required: ["x", "y"])
    }

    static let clickProperties: [String: JSONValue] = [
        "x": Schema.number("x in screenshot pixels."), "y": Schema.number("y in screenshot pixels."),
        "button": Schema.string("Which button (default left).", enum: ["left", "right", "middle"]),
        "count": Schema.integer("Clicks (2 for a double click).", minimum: 1, maximum: 3),
        "modifiers": Schema.array("Keys held during the click: shift, ctrl, alt, cmd.", items: Schema.string("A modifier key.")),
    ]

    static let verifiedNote =
        "The result's verified.status says whether the screen changed (changed, with changeRatio and bbox in screenshot "
        + "pixels), did not (unchanged: a change as small as one character or a checkbox can read so; look before "
        + "repeating an action) or could not be checked (unknown)."

    // MARK: - Actions as the helper takes them

    /// A tool's action (screenshot pixels, key names) as the helper takes it (guest pixels, HID usages).
    static func helperAction(_ kind: String, _ args: JSONValue, scale: Double) throws -> JSONValue {
        func number(_ value: JSONValue?, _ name: String) throws -> JSONValue {
            guard let value = value?.doubleValue else { throw ToolFailure("\(kind): \(name) is required") }
            return .double(value * scale)
        }
        func usages(_ combo: String) throws -> JSONValue {
            guard let usages = KeyCombo.usages(combo) else { throw ToolFailure("unknown key in \(combo.debugDescription)") }
            return .array(usages.map { .int(Int64($0)) })
        }
        switch kind {
        case "key":
            return ["type": "key", "usages": try usages(try args.string("combo"))]
        case "type":
            guard let text = args["text"]?.stringValue else { throw ToolFailure("type: text is required") }
            return ["type": "text", "text": .string(text), "submit": .bool(args["submit"] == true)]
        case "click":
            var modifiers: [JSONValue] = []
            for name in args["modifiers"]?.arrayItems ?? [] {
                guard let name = name.stringValue, let usage = KeyCombo.modifiers[name.lowercased()] else {
                    throw ToolFailure("click: modifiers are shift, ctrl, alt and cmd")
                }
                modifiers.append(.int(Int64(usage)))
            }
            return [
                "type": "click", "x": try number(args["x"], "x"), "y": try number(args["y"], "y"),
                "button": .string(args["button"]?.stringValue ?? "left"), "count": .int(min(max(args["count"]?.intValue ?? 1, 1), 3)),
                "modifiers": .array(modifiers),
            ]
        case "move":
            return ["type": "move", "x": try number(args["x"], "x"), "y": try number(args["y"], "y")]
        case "drag":
            return [
                "type": "drag",
                "from": ["x": try number(args["from"]?["x"], "from.x"), "y": try number(args["from"]?["y"], "from.y")],
                "to": ["x": try number(args["to"]?["x"], "to.x"), "y": try number(args["to"]?["y"], "to.y")],
            ]
        case "scroll":
            // The tool's down is positive; the helper's is negative.
            return ["type": "scroll", "dx": .double(args["dx"]?.doubleValue ?? 0), "dy": .double(-(args["dy"]?.doubleValue ?? 0))]
        case "wait":
            return ["type": "wait", "ms": .int(args["ms"]?.intValue ?? 0)]
        default:
            throw ToolFailure("unknown action type \(kind.debugDescription)")
        }
    }

    /// How long a batch may take: its waits and settling, its typing at QEMU's pace (130 ms a character), and slack.
    static func timeout(_ actions: [JSONValue], settleMs: Int) -> Duration {
        let waits = actions.reduce(0) { $0 + ($1["ms"]?.intValue ?? 0) }
        let characters = actions.reduce(0) { $0 + ($1["text"]?.stringValue?.count ?? 0) }
        return .seconds(60) + .milliseconds(Int(waits) + settleMs + characters * 150)
    }

    // MARK: - Running a batch

    /// Runs `actions` (as `helperAction` made them) and reads back the result. `done`: what a one-action tool did (its
    /// failure is the tool's); nil for vm_actions.
    static func run(_ access: VMAccess, _ vm: String, _ actions: [JSONValue], _ args: JSONValue, done: String?) async throws -> ToolResult {
        let single = done != nil
        let settleMs = Int(args["settle_ms"]?.intValue ?? 300)
        var params: [String: JSONValue] = ["actions": .array(actions), "settleMs": .int(Int64(settleMs))]
        if args["stop_on_error"] == false { params["stopOnError"] = false }
        let reply: JSONValue
        do {
            reply = try await access.call(vm, .vmInputBatch, .object(params), timeout: timeout(actions, settleMs: settleMs))
        } catch let failure as ToolFailure where isOutdatedHelper(failure) {
            reply = try await Legacy.run(access, vm, actions, settleMs: settleMs)
        }
        // The screenshot first: it sets the scale the box and the screen are given in.
        let shot =
            args["screenshot_after"] == true
            ? try await VMTools.screenshot(access).handler(["vm": .string(vm)], ToolContext(client: nil) { _, _, _ in }) : nil
        let scale = try await access.scale(for: vm)
        let results = (reply["results"]?.arrayItems ?? []).map { explained($0, vm: vm) }
        let failures = results.filter { $0["ok"] == false }
        if single, let failure = failures.first { throw ToolFailure(failure["error"]?.stringValue ?? "the input failed") }
        let verified = screenshotSpace(reply["verified"] ?? ["status": "unknown"], scale: scale)
        var structured: [String: JSONValue] = ["verified": verified]
        if !single { structured["results"] = .array(results) }
        if let width = reply["screen"]?["width"]?.doubleValue, let height = reply["screen"]?["height"]?.doubleValue {
            structured["screen"] = [
                "w": .int(Int64((width / scale).rounded())), "h": .int(Int64((height / scale).rounded())), "scale": .double(scale),
            ]
        }
        var lines = ["\(done ?? "done"): \(describe(verified))"]
        if !single {
            lines.insert("\(results.count - failures.count) of \(actions.count) actions done", at: 0)
            lines += failures.map { "action \($0["i"]?.intValue ?? -1) failed: \($0["error"]?.stringValue ?? "")" }
        }
        var result = ToolResult(text: lines.joined(separator: "\n"), structured: .object(structured), isError: !failures.isEmpty)
        if let shot { result.content += shot.content }
        return result
    }

    /// An action's result with a refusal explained as a single tool's would be.
    static func explained(_ result: JSONValue, vm: String) -> JSONValue {
        guard case .object(var fields) = result, let code = fields["code"]?.intValue, let message = fields["error"]?.stringValue else {
            return result
        }
        fields["error"] = .string(VMAccess.explain(RPCError(code: Int(code), message: message), vm: vm))
        fields["code"] = nil
        return .object(fields)
    }

    /// A helper started by an older VMPane (it keeps running after an update) has no `vm.input.batch`.
    static func isOutdatedHelper(_ failure: ToolFailure) -> Bool {
        failure.code == ControlErrorCode.methodNotFound.rawValue
            || failure.message.contains("\(ControlMethod.vmInputBatch.rawValue) is not an allowed method")
    }

    /// The helper's `verified` with its box in screenshot pixels.
    static func screenshotSpace(_ verified: JSONValue, scale: Double) -> JSONValue {
        guard case .object(var fields) = verified else { return verified }
        if let box = fields["bbox"] {
            func scaled(_ key: String) -> JSONValue { .int(Int64(((box[key]?.doubleValue ?? 0) / scale).rounded())) }
            fields["bbox"] = ["x": scaled("x"), "y": scaled("y"), "width": scaled("width"), "height": scaled("height")]
        }
        return .object(fields)
    }

    static func describe(_ verified: JSONValue) -> String {
        switch verified["status"]?.stringValue {
        case "changed":
            // Not locale-formatted: the model reads it.
            var percent = String(format: "%.1f", (verified["changeRatio"]?.doubleValue ?? 0) * 100)
            if percent.hasSuffix(".0") { percent.removeLast(2) }
            let box = verified["bbox"].map { box in
                let field = { (key: String) in box[key]?.intValue ?? 0 }
                return " around \(field("x")),\(field("y")) \(field("width"))×\(field("height"))"
            }
            return "the screen changed (\(percent)%\(box ?? ""))" + (verified["settled"] == false ? ", still changing" : "")
        case "unchanged": return "no visible change"
        default: return "whether the screen changed is unknown (\(verified["reason"]?.stringValue ?? "no display"))"
        }
    }

    // MARK: - Tools

    static func actions(_ access: VMAccess) -> Tool {
        let action = Schema.object(
            clickProperties.merging([
                "type": Schema.string("What to do.", enum: ["key", "type", "click", "move", "drag", "scroll", "wait"]),
                "combo": Schema.string("key: a key or combination (enter, cmd+c, ctrl+alt+delete)."),
                "text": Schema.string("type: the text (US keyboard layout)."),
                "submit": Schema.boolean("type: press Return afterwards."),
                "from": point("drag: start"), "to": point("drag: end"),
                "dx": Schema.number("scroll: right is positive (pixels)."), "dy": Schema.number("scroll: down is positive (pixels)."),
                "ms": Schema.integer("wait: milliseconds.", minimum: 0, maximum: 30000),
            ]) { $1 }, required: ["type"])
        var properties: [String: JSONValue] = [
            "vm": Schema.vm,
            "actions": Schema.array("The actions, in order (at most 50; waits at most 30 s together).", items: action, maxItems: 50),
            "stop_on_error": Schema.boolean("Stop at the first action that fails (default true)."),
        ]
        properties.merge(after) { $1 }
        return Tool(
            "vm_actions",
            "Several clicks, keys, typing, scrolls and waits in one call, each checked against the VM's agent access like "
                + "its own tool. " + verifiedNote,
            schema: Schema.object(properties, required: ["vm", "actions"]), annotations: writes
        ) { args, _ in
            let vm = try args.string("vm")
            let items = args["actions"]?.arrayItems ?? []
            guard !items.isEmpty else { throw ToolFailure("actions is required") }
            let scale = try await access.scale(for: vm)
            let actions = try items.map { try helperAction($0["type"]?.stringValue ?? "", $0, scale: scale) }
            return try await run(access, vm, actions, args, done: nil)
        }
    }

    /// A tool of one action (`vm_<kind>`).
    static func single(_ access: VMAccess, _ kind: String, _ description: String, _ properties: [String: JSONValue], required: [String])
        -> Tool
    {
        var properties = properties
        properties["vm"] = Schema.vm
        properties.merge(after) { $1 }
        let schema = Schema.object(properties, required: ["vm"] + required)
        return Tool("vm_\(kind)", description + " " + verifiedNote, schema: schema, annotations: writes) { args, _ in
            let vm = try args.string("vm")
            let action = try helperAction(kind, args, scale: try await access.scale(for: vm))
            return try await run(access, vm, [action], args, done: done(kind, args))
        }
    }

    /// What a one-action tool says it did.
    static func done(_ kind: String, _ args: JSONValue) -> String {
        switch kind {
        case "key": "pressed \(args["combo"]?.stringValue ?? "")"
        case "type": args["submit"] == true ? "typed and submitted" : "typed"
        case "drag": "dragged"
        case "move": "moved"
        default: "\(kind)ed"
        }
    }

    static func click(_ access: VMAccess) -> Tool {
        single(access, "click", "Click at a point of the screen.", clickProperties, required: ["x", "y"])
    }

    static func move(_ access: VMAccess) -> Tool {
        let properties = ["x": Schema.number("x in screenshot pixels."), "y": Schema.number("y in screenshot pixels.")]
        return single(access, "move", "Move the pointer (hover).", properties, required: ["x", "y"])
    }

    static func drag(_ access: VMAccess) -> Tool {
        let properties = ["from": point("Start"), "to": point("End")]
        return single(access, "drag", "Drag with the left button from one point to another.", properties, required: ["from", "to"])
    }

    static func scroll(_ access: VMAccess) -> Tool {
        let properties = ["dx": Schema.number("Right is positive (pixels)."), "dy": Schema.number("Down is positive (pixels).")]
        return single(access, "scroll", "Scroll where the pointer is.", properties, required: [])
    }

    static func type(_ access: VMAccess) -> Tool {
        let properties = [
            "text": Schema.string("What to type (US keyboard layout)."), "submit": Schema.boolean("Press Return afterwards."),
        ]
        return single(access, "type", "Type text into the VM.", properties, required: ["text"])
    }

    static func key(_ access: VMAccess) -> Tool {
        let properties = ["combo": Schema.string("A key or combination: enter, esc, f5, cmd+c, ctrl+alt+delete, shift+tab, up…")]
        return single(access, "key", "Press a key or a key combination.", properties, required: ["combo"])
    }
}

/// Input through a helper that has no `vm.input.batch` (started by an older VMPane): one request per event, as
/// VMPane did before, and no check of the screen.
struct Legacy {
    let access: VMAccess
    let vm: String

    static func run(_ access: VMAccess, _ vm: String, _ actions: [JSONValue], settleMs: Int) async throws -> JSONValue {
        let legacy = Legacy(access: access, vm: vm)
        for action in actions { try await legacy.perform(action) }
        try await Task.sleep(for: .milliseconds(settleMs))
        let results = actions.indices.map { JSONValue.object(["i": .int(Int64($0)), "ok": true]) }
        return ["results": .array(results), "verified": ["status": "unknown", "reason": "helper_outdated"]]
    }

    private func pointer(_ x: Double, _ y: Double, _ buttons: Int) async throws {
        _ = try await access.call(vm, .vmInputPointer, ["x": .double(x), "y": .double(y), "buttons": .int(Int64(buttons))])
    }

    private func keys(_ usages: [JSONValue], down: Bool) async throws {
        for usage in down ? usages : usages.reversed() {
            _ = try await access.call(vm, .vmInputKey, ["usage": usage, "down": .bool(down)])
        }
    }

    private func perform(_ action: JSONValue) async throws {
        let x = action["x"]?.doubleValue ?? 0, y = action["y"]?.doubleValue ?? 0
        switch action["type"]?.stringValue {
        case "key":
            try await keys(action["usages"]?.arrayItems ?? [], down: true)
            try await keys(action["usages"]?.arrayItems ?? [], down: false)
        case "text":
            _ = try await access.call(vm, .vmInputText, ["text": action["text"] ?? ""])
            if action["submit"] == true {
                try await keys([.int(0x28)], down: true)
                try await keys([.int(0x28)], down: false)
            }
        case "click":
            let bit = ["left": 1, "right": 2, "middle": 4][action["button"]?.stringValue ?? "left"] ?? 1
            try await keys(action["modifiers"]?.arrayItems ?? [], down: true)
            try await pointer(x, y, 0)
            for _ in 0..<max(1, Int(action["count"]?.intValue ?? 1)) {
                try await pointer(x, y, bit)
                try await Task.sleep(for: .milliseconds(40))
                try await pointer(x, y, 0)
                try await Task.sleep(for: .milliseconds(60))
            }
            try await keys(action["modifiers"]?.arrayItems ?? [], down: false)
        case "move":
            try await pointer(x, y, 0)
        case "drag":
            try await drag(action)
        case "scroll":
            _ = try await access.call(vm, .vmInputScroll, ["dx": action["dx"] ?? 0, "dy": action["dy"] ?? 0])
        case "wait":
            try await Task.sleep(for: .milliseconds(action["ms"]?.intValue ?? 0))
        default:
            break
        }
    }

    private func drag(_ action: JSONValue) async throws {
        let from = (action["from"]?["x"]?.doubleValue ?? 0, action["from"]?["y"]?.doubleValue ?? 0)
        let to = (action["to"]?["x"]?.doubleValue ?? 0, action["to"]?["y"]?.doubleValue ?? 0)
        try await pointer(from.0, from.1, 0)
        try await pointer(from.0, from.1, 1)
        for step in 1...10 {
            let fraction = Double(step) / 10
            try await pointer(from.0 + (to.0 - from.0) * fraction, from.1 + (to.1 - from.1) * fraction, 1)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await pointer(to.0, to.1, 0)
    }
}
