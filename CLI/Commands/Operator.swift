import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

/// Whether your own use of vmpane at a terminal acts as operator: allowed what the app allows, except app-only
/// actions, on any VM whatever its agent policy. Agents (MCP, scripts without a terminal) never are.
struct Operator: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Let your own terminal use of vmpane control VMs whatever their agent policy.",
        subcommands: [OperatorGrantCommand.self, OperatorRevoke.self, OperatorStatus.self])
}

struct OperatorGrantCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "grant", abstract: "Allow it (asks for confirmation).")

    func run() throws {
        guard InteractiveSession.isInteractive() else { CLI.fail("run this yourself, at a terminal", .policyDenied) }
        print("vmpane run by you at a terminal will be able to start, stop, exec in and change any VM, whatever")
        print("its agent policy (agents and scripts stay bound by it). Allow? [y/N] ", terminator: "")
        guard readLine()?.lowercased().hasPrefix("y") == true else { CLI.fail("not changed", .failure) }
        do {
            try OperatorGrant.grant(paths: CLI.paths)
        } catch {
            CLI.fail("cannot save the grant: \(error)", .failure)
        }
        print("granted (vmpane operator revoke takes it back)")
    }
}

struct OperatorRevoke: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Take it back.")

    func run() throws {
        do {
            try OperatorGrant.revoke(paths: CLI.paths)
        } catch {
            CLI.fail("cannot remove the grant: \(error)", .failure)
        }
    }
}

struct OperatorStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Whether this process acts as operator.")
    @OptionGroup var output: OutputOptions

    func run() {
        let granted = OperatorGrant.isGranted(paths: CLI.paths)
        let interactive = InteractiveSession.isInteractive()
        CLI.print(
            [
                "granted": .bool(granted), "interactive": .bool(interactive),
                "identity": .string(CLI.identity == .operator ? "operator" : "automated"),
            ], json: output.json
        ) {
            CLI.identity == .operator ? "operator" : granted ? "automated (not at a terminal)" : "automated (no grant)"
        }
    }
}
