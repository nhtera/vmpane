import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore
import VMPaneMCP

/// `vmpane mcp`: VMPane's MCP server on stdin/stdout, for AI agents (Claude Code, Codex CLI, Gemini CLI…). One
/// process is one agent session. It is always policy-bound, never operator, even started from a terminal: each
/// VM allows agents what its owner set in VMPane.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve VMPane to an AI agent over MCP (stdio).")

    func run() async throws {
        let session = UUID().uuidString.lowercased()
        let connector = HelperConnector(
            paths: CLI.paths, clientName: "vmpane mcp", clientVersion: VMPane.version, kind: "mcp", operatorClaim: false,
            sessionId: session, launch: CLI.launchHelper)
        let access = VMAccess(ops: LibraryOps(library: CLI.library, identity: .automated), connector: connector)
        // Files to and from VMs live in ~/VMPane Exchange/<vm>/ ($VMPANE_EXCHANGE_DIR for integration tests).
        let exchange =
            ProcessInfo.processInfo.environment["VMPANE_EXCHANGE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VMPane Exchange", isDirectory: true)
        let output = StandardOutput()
        let server = MCPServer(registry: VMPaneTools.registry(access, exchange: exchange), version: VMPane.version) { data in
            await output.write(data)
        }
        for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
            await server.receive(Data(line.utf8))
        }
        try? await Task.sleep(for: .seconds(1))  // stdin closed: let answers in flight go out
    }
}

/// One JSON message per line on stdout, never interleaved.
actor StandardOutput {
    func write(_ data: Data) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
