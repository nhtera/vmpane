import Foundation
import VMPaneControl
import VMPaneCore

/// The VM itself: list, status, power, screenshots, snapshots, clipboard, waiting.
enum VMTools {
    static let readOnly: JSONValue = ["readOnlyHint": true, "openWorldHint": false]

    static func all(_ access: VMAccess) -> [Tool] {
        [list(access), status(access), power(access), screenshot(access)] + snapshots(access) + clipboard(access)
            + [wait(access), signIn(access)]
    }

    static func signIn(_ access: VMAccess) -> Tool {
        Tool(
            "vm_sign_in",
            "Sign in to a VM that shows its login or lock screen, with the password its owner kept for it in VMPane (you never "
                + "see it). Only when the owner turned on Let agents sign in; at levels that run commands the person at the Mac is "
                + "asked first. If the screen lists users, click yours first. Returns verified.status signed_in once the guest "
                + "reports a signed-in session.",
            schema: Schema.object(["vm": Schema.vm], required: ["vm"]),
            annotations: ["destructiveHint": false, "openWorldHint": false]
        ) { args, _ in
            // The person may take up to a minute to answer; then up to 30 s for the guest.
            let result = try await access.call(try args.string("vm"), .vmSignIn, [:], timeout: .seconds(120))
            let status = result["verified"]?["status"]?.stringValue ?? "unknown"
            return ToolResult(text: status == "signed_in" ? "signed in" : "already signed in", structured: result)
        }
    }

    static func list(_ access: VMAccess) -> Tool {
        Tool(
            "vm_list", "The VMs you may use (others are hidden by their owner's setting), with their state.", schema: Schema.object([:]),
            annotations: readOnly
        ) { _, _ in
            var vms: [JSONValue] = []
            for item in try await access.list() {
                let state = (try? await access.call(item.id.uuidString, .vmInfo))?["state"]?.stringValue ?? "stopped"
                vms.append([
                    "id": .string(ShortID(item.id).rawValue), "name": .string(item.config?.name ?? "?"),
                    "os": .string(item.config?.os.rawValue ?? "?"), "state": .string(state),
                ])
            }
            let text =
                vms.isEmpty
                ? "No VMs are open to agents. Their owner can allow it in VMPane (Settings › AI agents)."
                : vms.map { vm in
                    let field = { (key: String) in vm[key]?.stringValue ?? "" }
                    return "\(field("name")) (\(field("os")), \(field("id"))): \(field("state"))"
                }
                .joined(separator: "\n")
            return ToolResult(text: text, structured: ["vms": .array(vms)])
        }
    }

    static func status(_ access: VMAccess) -> Tool {
        Tool(
            "vm_status", "A VM's state, what it can do now, and whether VMPane's guest tools are running in it.",
            schema: Schema.object(["vm": Schema.vm], required: ["vm"]), annotations: readOnly
        ) { args, _ in
            let vm = try args.string("vm")
            let info = try await access.call(vm, .vmInfo, launching: false)
            let agent = (try? await access.call(vm, .agentStatus)) ?? ["connected": false]
            let structured: JSONValue = ["info": info, "agent": agent]
            var tools = agent["connected"] == true ? "guest tools running" : "no guest tools"
            if agent["outdated"] == true { tools += " (older than VMPane's)" }
            return ToolResult(
                text: "\(info["name"]?.stringValue ?? vm): \(info["state"]?.stringValue ?? "?"), \(tools)", structured: structured)
        }
    }

    static func power(_ access: VMAccess) -> Tool {
        Tool(
            "vm_power",
            "Start, shut down (the power button), turn off at once, pause or resume a VM. A start can wait until VMPane's "
                + "guest tools run in it (wait_for).",
            schema: Schema.object(
                [
                    "vm": Schema.vm, "action": Schema.string("What to do.", enum: ["start", "stop", "force_stop", "pause", "resume"]),
                    "wait_for": Schema.string("start: return once this is ready (default none).", enum: ["none", "guest_tools"]),
                    "timeout_s": Schema.integer("wait_for: give up after this many seconds (default 120).", minimum: 1, maximum: 600),
                ],
                required: ["vm", "action"]),
            annotations: ["destructiveHint": true, "openWorldHint": false]
        ) { args, _ in
            let vm = try args.string("vm")
            guard let action = PowerAction.all[try args.string("action")] else {
                throw ToolFailure("action is start, stop, force_stop, pause or resume")
            }
            let result = try await access.call(vm, action.method, action.params, launching: action.launching, timeout: .seconds(180))
            let state = "\(vm): \(result["state"]?.stringValue ?? "?")"
            guard action.method == .vmStart, args["wait_for"] == "guest_tools" else { return ToolResult(text: state, structured: result) }
            let agent = try await waitForGuestTools(access, vm, timeout: .seconds(args["timeout_s"]?.intValue ?? 120))
            var structured = result.objectValue ?? [:]
            structured["guest"] = ["os": agent["os"] ?? "", "osVersion": agent["osVersion"] ?? "", "toolsVersion": agent["version"] ?? ""]
            let os = [agent["os"]?.stringValue, agent["osVersion"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
            return ToolResult(text: "\(state), guest tools running (\(os.joined(separator: " ")))", structured: .object(structured))
        }
    }

    static func screenshot(_ access: VMAccess) -> Tool {
        Tool(
            "vm_screenshot",
            "The VM's screen as an image. Coordinates for vm_click and the other input tools are pixels of this image.",
            schema: Schema.object(
                ["vm": Schema.vm, "max_edge": Schema.integer("Longest edge in pixels (default 1568).", minimum: 64, maximum: 8192)],
                required: ["vm"]),
            annotations: readOnly
        ) { args, _ in
            let vm = try args.string("vm")
            let shot = try await access.call(vm, .vmScreenshot, ["maxEdge": .int(args["max_edge"]?.intValue ?? 1568)])
            guard let data = shot["dataB64"]?.stringValue else { throw ToolFailure("no image came back") }
            let scale = shot["scale"]?.doubleValue ?? 1
            try await access.setScale(scale, for: vm)
            let width = shot["width"]?.intValue ?? 0
            let height = shot["height"]?.intValue ?? 0
            return ToolResult(
                content: [
                    ["type": "image", "data": .string(data), "mimeType": "image/png"],
                    ["type": "text", "text": .string("\(width)×\(height) (scale \(scale) to the VM's pixels)")],
                ], structured: ["width": .int(width), "height": .int(height), "scale": .double(scale)])
        }
    }

    static func snapshots(_ access: VMAccess) -> [Tool] {
        [
            Tool(
                "vm_snapshot_list", "The VM's snapshots.", schema: Schema.object(["vm": Schema.vm], required: ["vm"]),
                annotations: readOnly
            ) { args, _ in
                let list = try await access.call(try args.string("vm"), .vmSnapshotList, launching: true)
                guard case .array(let snapshots) = list else { return ToolResult(text: "none", structured: ["snapshots": []]) }
                let text = snapshots.map {
                    "\($0["name"]?.stringValue ?? "") (\($0["id"]?.stringValue ?? ""), \($0["kind"]?.stringValue ?? ""))"
                }
                return ToolResult(text: text.isEmpty ? "none" : text.joined(separator: "\n"), structured: ["snapshots": list])
            },
            Tool(
                "vm_snapshot_create", "Take a snapshot (with memory if the VM runs), to come back to with vm_snapshot_restore.",
                schema: Schema.object(["vm": Schema.vm, "name": Schema.string("Its name.")], required: ["vm", "name"]),
                annotations: ["destructiveHint": false, "openWorldHint": false]
            ) { args, _ in
                let vm = try args.string("vm")
                let state = try await access.call(vm, .vmInfo, launching: true)["state"]?.stringValue
                let kind = state == "running" || state == "paused" ? "live" : "disk"
                let meta = try await access.call(
                    vm, .vmSnapshotCreate, ["name": .string(try args.string("name")), "kind": .string(kind)], timeout: .seconds(600))
                // A live snapshot keeps the memory; a disk one of a stopped VM is a clean shutdown's disk, never a crash's.
                var structured = meta.objectValue ?? [:]
                structured["includesMemory"] = .bool(meta["kind"]?.stringValue ?? kind == "live")
                structured["crashConsistent"] = false
                return ToolResult(text: "snapshot \(meta["id"]?.stringValue ?? "") taken", structured: .object(structured))
            },
            Tool(
                "vm_snapshot_restore", "Go back to a snapshot. What changed since it was taken is lost.",
                schema: Schema.object(["vm": Schema.vm, "snapshot": Schema.string("Its id.")], required: ["vm", "snapshot"]),
                annotations: ["destructiveHint": true, "openWorldHint": false]
            ) { args, _ in
                let result = try await access.call(
                    try args.string("vm"), .vmSnapshotRestore, ["id": .string(try args.string("snapshot"))], launching: true,
                    timeout: .seconds(600))
                return ToolResult(text: "restored; the VM is \(result["state"]?.stringValue ?? "?")", structured: result)
            },
            Tool(
                "vm_snapshot_delete", "Delete a snapshot.",
                schema: Schema.object(["vm": Schema.vm, "snapshot": Schema.string("Its id.")], required: ["vm", "snapshot"]),
                annotations: ["destructiveHint": true, "openWorldHint": false]
            ) { args, _ in
                _ = try await access.call(
                    try args.string("vm"), .vmSnapshotDelete, ["id": .string(try args.string("snapshot"))], launching: true)
                return ToolResult(text: "deleted")
            },
        ]
    }

    static func clipboard(_ access: VMAccess) -> [Tool] {
        [
            Tool(
                "vm_clipboard_get", "The VM's clipboard text (macOS and Windows guests with VMPane's guest tools).",
                schema: Schema.object(["vm": Schema.vm], required: ["vm"]), annotations: readOnly
            ) { args, _ in
                let read = try await access.call(try args.string("vm"), .vmClipboardRead, ["types": ["text"]])
                let text = read["items"]?.arrayItems.first { $0["type"] == "text" }?["text"]?.stringValue ?? ""
                return ToolResult(text: text, structured: read)
            },
            Tool(
                "vm_clipboard_set", "Put text on the VM's clipboard (macOS and Windows guests with VMPane's guest tools).",
                schema: Schema.object(["vm": Schema.vm, "text": Schema.string("The text.")], required: ["vm", "text"]),
                annotations: ["destructiveHint": false, "openWorldHint": false]
            ) { args, _ in
                _ = try await access.call(
                    try args.string("vm"), .vmClipboardWrite, ["items": [["type": "text", "text": .string(try args.string("text"))]]])
                return ToolResult(text: "set")
            },
        ]
    }

    static func wait(_ access: VMAccess) -> Tool {
        Tool(
            "vm_wait", "Wait: a number of milliseconds, or until VMPane's guest tools are running in the VM.",
            schema: Schema.object(
                [
                    "vm": Schema.vm, "ms": Schema.integer("How long, at most 60000.", minimum: 0, maximum: 60000),
                    "until": Schema.string("Wait for this instead.", enum: ["agent"]),
                    "timeout_s": Schema.integer("Give up after this many seconds (default 120).", minimum: 1, maximum: 600),
                ], required: ["vm"]),
            annotations: readOnly
        ) { args, _ in
            let vm = try args.string("vm")
            if args["until"] == "agent" {
                _ = try await waitForGuestTools(access, vm, timeout: .seconds(args["timeout_s"]?.intValue ?? 120))
                return ToolResult(text: "the guest tools are running")
            }
            try await Task.sleep(for: .milliseconds(min(max(args["ms"]?.intValue ?? 1000, 0), 60000)))
            return ToolResult(text: "waited")
        }
    }
}

extension VMTools {
    /// Waits until VMPane's guest tools are connected in the VM (`vm_wait until agent`, `vm_power start wait_for`);
    /// their `agent.status`.
    static func waitForGuestTools(_ access: VMAccess, _ vm: String, timeout: Duration) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let status = try? await access.call(vm, .agentStatus), status["connected"] == true { return status }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ToolFailure("the guest tools did not start in time")
    }
}

/// What vm_power does for each action.
struct PowerAction {
    let method: ControlMethod
    let params: JSONValue?
    let launching: Bool

    static let all: [String: PowerAction] = [
        "start": PowerAction(method: .vmStart, params: ["headless": true], launching: true),
        "stop": PowerAction(method: .vmStop, params: ["mode": "graceful"], launching: false),
        "force_stop": PowerAction(method: .vmStop, params: ["mode": "force"], launching: false),
        "pause": PowerAction(method: .vmPause, params: nil, launching: false),
        "resume": PowerAction(method: .vmResume, params: nil, launching: false),
    ]
}

extension JSONValue {
    /// A required string argument.
    func string(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else { throw ToolFailure("\(key) is required") }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    var arrayItems: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }
}
