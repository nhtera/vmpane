import Darwin
import Foundation
import VMPaneCore

@testable import VMPaneHost

/// The real Rust agent (`agent/target/debug/vmpane-agent`, built by `cargo build`, or `$VMPANE_AGENT_BINARY`, e.g.
/// an earlier release's agent in scripts/agent-compat.sh) dialing a Unix socket on this Mac, for tests of the host
/// side against it. Tests using it are skipped when the agent is not built.
let agentBinary: URL = {
    if let path = ProcessInfo.processInfo.environment["VMPANE_AGENT_BINARY"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Tests/VMPaneHostTests/Agent
        .deletingLastPathComponent().deletingLastPathComponent()  // Tests
        .deletingLastPathComponent().deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("agent/target/debug/vmpane-agent")
}()

let agentBuilt = FileManager.default.isExecutableFile(atPath: agentBinary.path)

/// A running agent process and the host's end of its connection (not yet through `hello`).
struct SpawnedAgent {
    let fd: Int32
    let process: Process
    let directory: URL

    /// `extra`: more agent arguments (e.g. `--session-socket`).
    static func spawn(_ extra: [String] = []) async throws -> SpawnedAgent {
        let directory = URL(fileURLWithPath: "/tmp/vpa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("s")
        let listener = try UnixSocket.make()
        defer { close(listener) }
        try UnixSocket.bind(listener, to: UnixSocketAddress(socketURL))
        guard listen(listener, 1) == 0 else { throw POSIXError(.EIO) }
        let process = Process()
        process.executableURL = agentBinary
        process.arguments = ["--connect", "unix:\(socketURL.path)", "--once"] + extra
        process.standardError = FileHandle.nullDevice
        try process.run()
        let fd = try await Blocking.run { () throws -> Int32 in
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 10_000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            return accept(listener, nil, nil)
        }
        return SpawnedAgent(fd: fd, process: process, directory: directory)
    }

    func cleanUp() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}
