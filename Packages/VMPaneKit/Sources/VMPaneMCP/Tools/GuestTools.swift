import Foundation
import VMPaneControl
import VMPaneCore

/// Work inside the guest through VMPane's guest tools: commands and files. Files on the Mac side live only in
/// `~/VMPane Exchange/<vm>/` (paths are relative to it).
enum GuestTools {
    static let outputCap = 256 << 10

    static func all(_ access: VMAccess, exchange: URL) -> [Tool] {
        [exec(access), push(access, exchange: exchange), pull(access, exchange: exchange)]
    }

    static func exec(_ access: VMAccess) -> Tool {
        Tool(
            "vm_exec",
            "Run a command in the VM (VMPane's guest tools) and get its output and exit code. "
                + "as: user (the logged-in user, default) or admin.",
            schema: Schema.object(
                [
                    "vm": Schema.vm, "command": Schema.string("A shell command line (sh -c / cmd /c)."),
                    "argv": [
                        "type": "array", "items": ["type": "string"], "description": "Or the program and its arguments, without a shell.",
                    ],
                    "as": Schema.string("Who runs it.", enum: ["user", "admin"]), "cwd": Schema.string("Working directory."),
                    "timeout_s": Schema.integer("Kill it after this many seconds (default 120).", minimum: 1, maximum: 3600),
                    "stdin": Schema.string("Text for its standard input."),
                ], required: ["vm"]),
            annotations: ["destructiveHint": true, "openWorldHint": true]
        ) { args, context in
            let vm = try args.string("vm")
            var params: [String: JSONValue] = [
                "as": .string(args["as"]?.stringValue ?? "user"), "timeoutMs": .int((args["timeout_s"]?.intValue ?? 120) * 1000),
            ]
            // Given with the command: the person asked to allow it sees it, and the record keeps its hash.
            if let input = args["stdin"]?.stringValue { params["input"] = .string(input) }
            if let argv = args["argv"], !argv.arrayItems.isEmpty {
                params["argv"] = argv
            } else {
                params["shell"] = .string(try args.string("command"))
            }
            if let cwd = args["cwd"]?.stringValue { params["cwd"] = .string(cwd) }
            let outcome = try await access.withOwnConnection(vm) { client in
                try await run(client, params: .object(params), context: context)
            }
            let code = outcome.code.map { "exit code \($0)" } ?? (outcome.timedOut ? "timed out" : "ended by \(outcome.signal ?? "?")")
            var text = outcome.stdout
            if !outcome.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + outcome.stderr }
            return ToolResult(
                text: (text.isEmpty ? "" : text + "\n") + "[\(code)]",
                structured: [
                    "exitCode": outcome.code.map { .int(Int64($0)) } ?? .null, "stdout": .string(outcome.stdout),
                    "stderr": .string(outcome.stderr),
                    "timedOut": .bool(outcome.timedOut), "truncated": .bool(outcome.truncated),
                ],
                isError: outcome.code != 0)
        }
    }

    struct Outcome: Sendable {
        var stdout = ""
        var stderr = ""
        var code: Int?
        var signal: String?
        var timedOut = false
        var truncated = false
    }

    /// Starts the command on its own connection and collects its output until it exits.
    static func run(_ client: UDSClient, params: JSONValue, context: ToolContext) async throws -> Outcome {
        let notes = client.notifications
        let started = try await client.call(ControlMethod.agentExec.rawValue, params: params)
        guard let execId = started["execId"]?.intValue else { throw ToolFailure("the VM did not start the command") }
        var outcome = Outcome()
        var stdout = Data()
        var stderr = Data()
        for await note in notes where note.params?["execId"]?.intValue == execId {
            if note.method == ControlNotification.execOutput.rawValue {
                let data = note.params?["dataB64"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
                let isError = note.params?["stream"] == "stderr"
                let room = outputCap - (isError ? stderr.count : stdout.count)
                if data.count > room { outcome.truncated = true }
                if isError { stderr.append(data.prefix(max(room, 0))) } else { stdout.append(data.prefix(max(room, 0))) }
            } else if note.method == ControlNotification.execExited.rawValue {
                outcome.code = note.params?["code"]?.intValue.map(Int.init)
                outcome.signal = note.params?["signal"]?.stringValue
                outcome.timedOut = note.params?["timedOut"] == true
                break
            }
        }
        if Task.isCancelled, outcome.code == nil, outcome.signal == nil {
            // The call was cancelled: the command goes too (outside this cancelled task, so the request is sent).
            await Task {
                _ = try? await client.call(ControlMethod.agentExecSignal.rawValue, params: ["execId": .int(execId), "signal": "kill"])
            }.value
        }
        outcome.stdout = String(bytes: stdout, encoding: .utf8) ?? String(bytes: stdout, encoding: .isoLatin1) ?? ""
        outcome.stderr = String(bytes: stderr, encoding: .utf8) ?? String(bytes: stderr, encoding: .isoLatin1) ?? ""
        return outcome
    }

    /// `relative` inside the VM's exchange folder (created), never outside it.
    static func exchangeFile(_ exchange: URL, vm: String, _ relative: String) throws -> URL {
        guard let folderName = SafeName.component(vm) else { throw ToolFailure("bad VM name") }
        guard let parts = SafeName.components(relative) else {
            throw ToolFailure("host_path is a path inside ~/VMPane Exchange/\(folderName)/, without ..")
        }
        guard !parts.isEmpty, !relative.hasPrefix("/") else {
            throw ToolFailure("host_path is relative to ~/VMPane Exchange/\(folderName)/")
        }
        let folder = exchange.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return parts.reduce(folder) { $0.appendingPathComponent($1) }
    }

    static func push(_ access: VMAccess, exchange: URL) -> Tool {
        Tool(
            "vm_file_push", "Copy a file from ~/VMPane Exchange/<vm>/ on the Mac into the VM.",
            schema: Schema.object(
                [
                    "vm": Schema.vm, "host_path": Schema.string("The file, relative to ~/VMPane Exchange/<vm>/."),
                    "guest_path": Schema.string("Where in the VM (absolute)."), "overwrite": Schema.boolean("Replace an existing file."),
                ], required: ["vm", "host_path", "guest_path"]),
            annotations: ["destructiveHint": true, "openWorldHint": false]
        ) { args, _ in
            let vm = try args.string("vm")
            let name = try await access.item(vm).config?.name ?? vm
            let source = try exchangeFile(exchange, vm: name, try args.string("host_path"))
            let result = try await access.call(
                vm, .agentFilePush,
                [
                    "hostPath": .string(source.path), "guestPath": .string(try args.string("guest_path")),
                    "overwrite": .bool(args["overwrite"] == true),
                ],
                timeout: .seconds(3600))
            return ToolResult(text: "copied \(result["bytes"]?.intValue ?? 0) bytes", structured: result)
        }
    }

    static func pull(_ access: VMAccess, exchange: URL) -> Tool {
        Tool(
            "vm_file_pull", "Copy a file from the VM to ~/VMPane Exchange/<vm>/ on the Mac.",
            schema: Schema.object(
                [
                    "vm": Schema.vm, "guest_path": Schema.string("The file in the VM (absolute)."),
                    "host_path": Schema.string("Where, relative to ~/VMPane Exchange/<vm>/."),
                    "overwrite": Schema.boolean("Replace an existing file."),
                ], required: ["vm", "guest_path", "host_path"]),
            annotations: ["destructiveHint": false, "openWorldHint": false]
        ) { args, _ in
            let vm = try args.string("vm")
            let name = try await access.item(vm).config?.name ?? vm
            let target = try exchangeFile(exchange, vm: name, try args.string("host_path"))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try await access.call(
                vm, .agentFilePull,
                [
                    "guestPath": .string(try args.string("guest_path")), "hostPath": .string(target.path),
                    "overwrite": .bool(args["overwrite"] == true),
                ],
                timeout: .seconds(3600))
            return ToolResult(text: "copied \(result["bytes"]?.intValue ?? 0) bytes to \(target.path)", structured: result)
        }
    }
}
