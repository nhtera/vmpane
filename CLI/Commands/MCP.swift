import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore
import VMPaneMCP

/// `vmpane mcp`: VMPane's MCP server on stdin/stdout, for AI agents (Claude Code, Codex CLI, Gemini CLI…). One
/// process is one agent session. It is always policy-bound, never operator, even started from a terminal: each
/// VM allows agents what its owner set in VMPane.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve VMPane to an AI agent over MCP (stdio), or stop all agents.",
        subcommands: [MCPServe.self, MCPKill.self, MCPConfig.self], defaultSubcommand: MCPServe.self)
}

/// Adds VMPane to an AI client's MCP configuration: shows the change, and makes it with --apply (after a backup).
struct MCPConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Add VMPane to Claude Code, Codex CLI or Gemini CLI (shows the change; --apply makes it).")
    @Argument(help: "claude, codex or gemini") var client: String
    @Flag(help: "Make the change (the old file is kept as a backup).") var apply = false

    func run() throws {
        guard let which = ClientConfigWriter.Client(rawValue: client) else { CLI.fail("the client is claude, codex or gemini", .usage) }
        let vmpane = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let claudeOnPath = which == .claude && Self.onPath("claude")
        let change: ClientConfigWriter.Change
        do {
            change = try ClientConfigWriter.change(
                for: which, vmpane: vmpane, home: Self.home, claudeOnPath: claudeOnPath)
        } catch {
            CLI.fail("cannot read the client's settings: \(error)", .failure)
        }
        guard apply else {
            print(change.summary)
            if let after = change.after, let file = change.file {
                print("\nNew \(file.lastPathComponent):\n\(after)")
                print("Run again with --apply to write it (the old file is kept as a backup).")
            } else if change.command != nil {
                print("Run again with --apply to run it.")
            }
            return
        }
        if let command = change.command {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { CLI.fail("\(command.joined(separator: " ")) failed", .failure) }
            return
        }
        guard change.file != nil else {
            print(change.summary)
            return
        }
        do {
            let backup = try ClientConfigWriter.apply(change)
            print("updated \(change.file?.path ?? "")" + (backup.map { " (backup: \($0.lastPathComponent))" } ?? ""))
        } catch {
            CLI.fail("cannot write the client's settings: \(error)", .failure)
        }
    }

    /// $HOME, like other command-line tools (Foundation's home ignores it).
    static var home: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func onPath(_ program: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(program)")
        }
    }
}

/// Stops every AI agent at once (any VM, any helper), with or without the app running; only the app lets them
/// act again.
struct MCPKill: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kill", abstract: "Stop every AI agent now.")

    func run() {
        do {
            try KillSwitch.engage(paths: CLI.paths)
        } catch {
            CLI.fail("cannot engage the kill switch: \(error)", .failure)
        }
        print("AI agents are stopped. VMPane (menu bar) lets them act again.")
    }
}

struct MCPServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Serve VMPane over MCP on stdin/stdout (the default).")

    func run() async throws {
        let session = UUID().uuidString.lowercased()
        let connector = HelperConnector(
            paths: CLI.paths, clientName: "vmpane mcp", clientVersion: VMPane.version, kind: "mcp", operatorClaim: false,
            sessionId: session, launch: CLI.launchHelper)
        let ops = LibraryOps(library: CLI.library, identity: .automated).recordingInVMLogs(label: "cli", kind: "mcp", session: session)
        let access = VMAccess(ops: ops, connector: connector)
        // Files to and from VMs live in ~/VMPane Exchange/<vm>/ ($VMPANE_EXCHANGE_DIR for integration tests, in
        // development builds only: an agent that sets the environment must not move where files land).
        let testBuild = PeerIdentity.selfIdentity()?.isAdHoc ?? true
        let exchange =
            ProcessInfo.processInfo.environment["VMPANE_EXCHANGE_DIR"].flatMap {
                testBuild ? URL(fileURLWithPath: $0, isDirectory: true) : nil
            }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VMPane Exchange", isDirectory: true)
        let output = StandardOutput()
        let server = MCPServer(registry: VMPaneTools.registry(access, exchange: exchange), version: VMPane.version) { data in
            await output.write(data)
        }
        for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
            await server.receive(Data(line.utf8))
            if let client = await server.clientName { await access.setClient(client) }
        }
        await server.drain(within: .seconds(60))  // stdin closed: let answers in flight go out
    }
}

/// One JSON message per line on stdout, never interleaved.
actor StandardOutput {
    func write(_ data: Data) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
