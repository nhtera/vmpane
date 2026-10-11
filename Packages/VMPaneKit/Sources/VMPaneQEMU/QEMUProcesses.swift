import Darwin
import Foundation
import VMPaneCore

public enum QEMUStartError: Error, Equatable, Sendable, CustomStringConvertible {
    /// swtpm or QEMU exited while starting; `log` is the end of its log.
    case exitedDuringStart(program: String, exit: ChildExit, log: String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .exitedDuringStart(let program, let exit, let log): "\(program) \(exit) while starting\(log.isEmpty ? "" : ":\n\(log)")"
        case .timedOut(let what): "timed out waiting for \(what)"
        }
    }
}

/// Spawns swtpm and QEMU for one VM: under their sandbox profiles, recorded in `run/<sid>.children` before
/// they run, holding the bundle lock (both write the VM's files), with `TMPDIR` in the run directory.
public struct QEMUProcesses: Sendable {
    public internal(set) var layout: QEMULayout
    /// Records children durably (`run/<sid>.children`); a successor helper reaps them after a crash.
    public let spawn: @Sendable (URL, ChildSpawner.Options) throws -> ProcessRecord
    /// Drops a child that has exited from the record.
    public let forget: @Sendable (ProcessRecord) -> Void
    /// The bundle lock's descriptor, inherited by both children.
    public let lockDescriptor: Int32
    public var sandboxed = true

    public init(
        layout: QEMULayout, lockDescriptor: Int32, spawn: @escaping @Sendable (URL, ChildSpawner.Options) throws -> ProcessRecord,
        forget: @escaping @Sendable (ProcessRecord) -> Void
    ) {
        self.layout = layout
        self.lockDescriptor = lockDescriptor
        self.spawn = spawn
        self.forget = forget
    }

    /// A minimal environment: nothing from the helper's leaks into the children.
    var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin", "TMPDIR": layout.runDirectory.path + "/", "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
    }

    /// Starts swtpm on the VM's TPM state and waits until its control socket exists. swtpm cannot escape
    /// commas in option values and its socket path must fit `sun_path`, so it runs in the run directory and gets
    /// both by relative path: the state directory through the `tpmstate` link.
    public func startSwtpm() async throws -> (ProcessRecord, ChildExitWatcher) {
        try FileManager.default.createDirectory(
            at: layout.tpmState, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: layout.tpmSocket)
        try? FileManager.default.removeItem(at: layout.tpmStateLink)
        try FileManager.default.createSymbolicLink(at: layout.tpmStateLink, withDestinationURL: layout.tpmState)
        let arguments = [
            "socket", "--tpm2", "--tpmstate", "dir=\(layout.tpmStateLink.lastPathComponent),mode=0600",
            "--ctrl", "type=unixio,path=\(layout.socketArgument(layout.tpmSocket)),mode=0600", "--terminate",
        ]
        let (record, watcher) = try launch(
            .swtpm, layout.installation.swtpm, arguments, log: layout.swtpmLog, workingDirectory: layout.runDirectory)
        try await waitFor("the TPM socket", watcher: watcher, program: "swtpm", log: layout.swtpmLog) {
            FileManager.default.fileExists(atPath: layout.tpmSocket.path)
        }
        return (record, watcher)
    }

    public func startQEMU(_ arguments: [String]) throws -> (ProcessRecord, ChildExitWatcher) {
        for socket in [layout.qmpSocket, layout.spiceSocket, layout.agentSocket] { try? FileManager.default.removeItem(at: socket) }
        return try launch(.qemu, layout.installation.qemuSystem, arguments, log: layout.qemuLog, workingDirectory: layout.runDirectory)
    }

    private func launch(
        _ program: QEMUSandbox.Program, _ executable: URL, _ arguments: [String], log: URL, workingDirectory: URL
    ) throws -> (ProcessRecord, ChildExitWatcher) {
        let options = ChildSpawner.Options(
            arguments: sandboxed
                ? try QEMUSandbox.arguments(program, executable: executable, arguments: arguments, layout: layout) : arguments,
            environment: environment, inheriting: [lockDescriptor], logFile: log, recordsExecutable: !sandboxed,
            workingDirectory: workingDirectory)
        let record = try spawn(sandboxed ? QEMUSandbox.sandboxExec : executable, options)
        return (record, ChildExitWatcher(pid: record.pid))
    }

    /// Polls `condition` until it holds; fails early when the child exits, or after `timeout`.
    func waitFor(
        _ what: String, watcher: ChildExitWatcher, program: String, log: URL, timeout: Duration = .seconds(15),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if let exit = watcher.exit {
                throw QEMUStartError.exitedDuringStart(program: program, exit: exit, log: Self.tail(of: log))
            }
            guard ContinuousClock.now < deadline else { throw QEMUStartError.timedOut(what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The last `lines` lines of a log (at most the last 64 KiB are read).
    public static func tail(of log: URL, lines: Int = 200) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(bytes: (try? handle.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
