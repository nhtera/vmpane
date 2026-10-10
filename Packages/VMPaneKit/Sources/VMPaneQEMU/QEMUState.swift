import Foundation
import VMPaneCore

public enum QEMUStateError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Saved RAM state from another QEMU build (QEMU cannot load it reliably): the VM boots fresh.
    case incompatible(saved: String, running: String)
    case missing(String)
    case migrationFailed(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .incompatible(let saved, let running): "the saved memory state is from QEMU \(saved), this is QEMU \(running)"
        case .missing(let path): "no saved memory state at \(path)"
        case .migrationFailed(let reason): "saving or loading the memory state failed: \(reason)"
        case .timedOut(let what): "\(what) timed out"
        }
    }
}

/// Guest RAM state for suspend and live snapshots: QEMU migration to a plain file (S12: never while the
/// guest runs, `stop` first; the bandwidth cap raised; the swtpm state travels in the stream). Restored by a
/// new QEMU started with `-incoming defer`, then `migrate-incoming` and `cont`.
enum QEMUState {
    static let fileName = "state.qemu"
    /// Which QEMU wrote the state (`{"qemu": "11.1.2"}`): only the same build loads it.
    static let infoName = "state-qemu.json"
    /// No cap: the default (128 MiB/s) makes saves several times slower.
    static let maxBandwidth: Int64 = 1 << 40
    /// Migration commands on a busy host can take longer than QMP's default 5 s to answer.
    static let commandTimeout = Duration.seconds(30)

    struct Info: Codable, Equatable {
        var qemu: String
    }

    /// "11.1.2" (+ package) from the QMP greeting.
    static func version(of qmp: QMPClient) -> String {
        let qemu = qmp.version?["qemu"]
        let numbers = ["major", "minor", "micro"].map { qemu?[$0]?.intValue.map(String.init) ?? "?" }.joined(separator: ".")
        let package = qmp.version?["package"]?.stringValue ?? ""
        return package.isEmpty ? numbers : "\(numbers) (\(package))"
    }

    /// A file migration channel (the structured form: a path is never parsed as a URI, so commas are fine).
    static func channel(_ file: URL) -> JSONValue {
        [["channel-type": "main", "addr": ["transport": "file", "filename": .string(file.path), "offset": 0]]]
    }

    /// Saves the paused VM's RAM state to `file`.
    static func save(_ qmp: QMPClient, to file: URL, memoryMiB: Int) async throws {
        try await qmp.execute("migrate-set-parameters", ["max-bandwidth": .int(maxBandwidth)], timeout: commandTimeout)
        try await qmp.execute("migrate", ["channels": channel(file)], timeout: commandTimeout)
        try await waitForMigration(qmp, what: "saving the memory state", memoryMiB: memoryMiB)
        let info = try JSONEncoder().encode(Info(qemu: version(of: qmp)))
        try DurableWrite.write(info, to: file.deletingLastPathComponent().appendingPathComponent(infoName))
    }

    /// Loads the state into a QEMU started with `-incoming defer`; the VM stays paused.
    static func load(_ qmp: QMPClient, from directory: URL, memoryMiB: Int) async throws {
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw QEMUStateError.missing(file.path) }
        let saved = (try? Data(contentsOf: directory.appendingPathComponent(infoName))).flatMap {
            try? JSONDecoder().decode(Info.self, from: $0)
        }
        let running = version(of: qmp)
        guard let saved, saved.qemu == running else { throw QEMUStateError.incompatible(saved: saved?.qemu ?? "unknown", running: running) }
        try await qmp.execute("migrate-incoming", ["channels": channel(file)], timeout: commandTimeout)
        try await waitForMigration(qmp, what: "loading the memory state", memoryMiB: memoryMiB)
    }

    /// Polls `query-migrate` until it completes or fails. A deferred incoming migration that never starts
    /// sits in "setup" forever (S12), so everything has a deadline: 30 s plus 10 s per GiB of guest RAM.
    static func waitForMigration(_ qmp: QMPClient, what: String, memoryMiB: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30 + 10 * max(1, memoryMiB / 1024))
        while true {
            let status = try await qmp.execute("query-migrate", timeout: commandTimeout)
            switch status["status"]?.stringValue {
            case "completed":
                return
            case "failed", "cancelled":
                throw QEMUStateError.migrationFailed(status["error-desc"]?.stringValue ?? "status \(status["status"]?.stringValue ?? "?")")
            default:
                guard ContinuousClock.now < deadline else { throw QEMUStateError.timedOut(what) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
