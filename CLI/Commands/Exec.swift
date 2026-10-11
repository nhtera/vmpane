import ArgumentParser
import Darwin
import Foundation
import VMPaneControl
import VMPaneCore

/// Runs a command in a running VM through its guest agent: output streams back as it comes, piped stdin goes in,
/// and vmpane exits with the command's exit code (128 + n after signal n).
struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command in a running VM (needs VMPane's guest tools).")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Option(name: .customLong("as"), help: "user (the logged-in user) or admin (root / SYSTEM).") var runAs = "user"
    @Option(help: "Working directory in the guest.") var cwd: String?
    @Option(name: .customLong("env"), help: "An environment variable, NAME=value (repeatable).") var environment: [String] = []
    @Option(help: "Kill the command after this many seconds.") var timeout: Int?
    @Argument(parsing: .postTerminator, help: "The command and its arguments, after --.") var command: [String] = []

    func run() async throws {
        try await CLI.guarded {
            guard !command.isEmpty else { throw RPCError(.invalidParams, "give the command after --, e.g. vmpane exec ubuntu -- uname -a") }
            guard ["user", "admin"].contains(runAs) else { throw RPCError(.invalidParams, "--as is user or admin") }
            let env = try parsedEnvironment()
            let session = try await CLI.running(try CLI.item(vm))
            defer { session.client.close() }
            let pipedInput = isatty(STDIN_FILENO) == 0
            var params: [String: JSONValue] = [
                "argv": .array(command.map { .string($0) }), "as": .string(runAs), "stdin": .bool(pipedInput), "env": .object(env),
            ]
            if let cwd { params["cwd"] = .string(cwd) }
            if let timeout { params["timeoutMs"] = .int(Int64(timeout) * 1000) }
            let notes = session.client.notifications
            let started = try await session.client.call(ControlMethod.agentExec.rawValue, params: .object(params))
            guard let execId = started["execId"]?.intValue else { throw RPCError(.internalError, "the helper gave no exec id") }
            if pipedInput { Task { await feedStdin(session.client, execId: execId) } }
            try await relay(notes, execId: execId)
        }
    }

    private func parsedEnvironment() throws -> [String: JSONValue] {
        var env: [String: JSONValue] = [:]
        for pair in environment {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                throw RPCError(.invalidParams, "--env takes NAME=value")
            }
            env[String(pair[..<equals])] = .string(String(pair[pair.index(after: equals)...]))
        }
        return env
    }

    /// The command's output to ours until it exits; then its exit code is ours.
    private func relay(_ notes: AsyncStream<RPCRequest>, execId: Int64) async throws {
        for await note in notes where note.params?["execId"]?.intValue == execId {
            switch note.method {
            case ControlNotification.execOutput.rawValue:
                let data = note.params?["dataB64"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
                (note.params?["stream"] == "stderr" ? FileHandle.standardError : FileHandle.standardOutput).write(data)
            case ControlNotification.execExited.rawValue:
                let code = note.params?["code"]?.intValue
                if code == 0 { return }
                if let code { throw ArgumentParser.ExitCode(Int32(truncatingIfNeeded: code)) }
                if note.params?["timedOut"] == true { CLI.fail("the command timed out", .failure) }
                let signal = note.params?["signal"]?.stringValue ?? "?"
                CLI.fail(signal == "disconnected" ? "the guest agent went away" : "the command ended by signal \(signal)", .failure)
            default:
                continue
            }
        }
        CLI.fail("the VM's helper closed the connection", .unavailable)
    }

    /// Our stdin into the command's, then end-of-file.
    private func feedStdin(_ client: UDSClient, execId: Int64) async {
        while let data = try? FileHandle.standardInput.read(upToCount: 64 << 10), !data.isEmpty {
            _ = try? await client.call(
                ControlMethod.agentExecInput.rawValue, params: ["execId": .int(execId), "dataB64": .string(data.base64EncodedString())])
        }
        _ = try? await client.call(ControlMethod.agentExecInput.rawValue, params: ["execId": .int(execId), "eof": true])
    }
}
