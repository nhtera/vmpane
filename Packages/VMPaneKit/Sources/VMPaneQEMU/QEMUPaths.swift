import Foundation
import VMPaneCore

/// A QEMU tool set: `bin/` (qemu-system-aarch64, qemu-img, swtpm), `lib/` and `share/`
/// (firmware, keymaps, ROMs; passed to QEMU with `-L`).
public struct QEMUInstallation: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// `VMPANE_QEMU_PATH`, honoured by Debug builds only.
        case environment
        /// The Advanced-settings override.
        case userOverride
        /// The helper's versioned runtime copy of the QEMU shipped in the app.
        case runtimeCopy
    }

    public let root: URL
    public let source: Source

    public init(root: URL, source: Source) {
        self.root = root
        self.source = source
    }

    public var qemuSystem: URL { tool("qemu-system-aarch64") }
    public var qemuImg: URL { tool("qemu-img") }
    public var swtpm: URL { tool("swtpm") }
    public var share: URL { root.appendingPathComponent("share", isDirectory: true) }

    private func tool(_ name: String) -> URL {
        root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(name)
    }
}

public enum QEMUPathError: Error, Equatable, CustomStringConvertible {
    /// A policy-bound client (CLI, MCP) asked for a start while the user has a QEMU override set.
    case overrideNeedsApp(path: String)
    /// The chosen QEMU failed validation; there is no fallback to another one.
    case invalid(path: String, reason: String)

    public var description: String {
        switch self {
        case .overrideNeedsApp(let path):
            "A custom QEMU is set (\(path)); start this VM from VMPane"
        case .invalid(let path, let reason):
            "QEMU at \(path) cannot be used: \(reason)"
        }
    }
}

/// Picks the QEMU a helper runs, in priority order:
/// 1. `VMPANE_QEMU_PATH` (a directory holding `bin/`), only in Debug builds;
/// 2. the user's override from Advanced settings, never for launches by policy-bound clients;
/// 3. the runtime copy (`runtime/<version>/qemu`), so an app update never swaps QEMU under a running helper.
/// The pick is then validated; a failing override is an error naming its path, not a silent fallback,
/// because an override runs arbitrary binaries as the user.
public enum QEMUPaths {
    public static let environmentKey = "VMPANE_QEMU_PATH"
    /// UserDefaults key (domain `app.vmpane.mac`) of the Advanced-settings override.
    public static let defaultsKey = "qemuPathOverride"
    /// Oldest QEMU major version the launcher's arguments are written for.
    public static let minimumMajor = 11

    /// Release builds ignore the environment override.
    public static var environmentOverrideAllowed: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    public struct Inputs: Sendable {
        public var environment: [String: String]
        /// The Advanced-settings override, already checked against its integrity tag by the caller.
        public var userOverride: URL?
        /// The helper was launched for the CLI or an MCP client (policy-bound), not by the app.
        public var policyBoundLaunch: Bool
        public var runtimeCopy: URL
        public var allowEnvironmentOverride: Bool

        public init(
            environment: [String: String] = ProcessInfo.processInfo.environment, userOverride: URL? = nil,
            policyBoundLaunch: Bool = false, runtimeCopy: URL,
            allowEnvironmentOverride: Bool = QEMUPaths.environmentOverrideAllowed
        ) {
            self.environment = environment
            self.userOverride = userOverride
            self.policyBoundLaunch = policyBoundLaunch
            self.runtimeCopy = runtimeCopy
            self.allowEnvironmentOverride = allowEnvironmentOverride
        }
    }

    /// What `qemu-system-aarch64 --version` and `-accel help` printed (nil: did not run or failed).
    public struct Probe: Sendable, Equatable {
        public var version: String?
        public var accelerators: String?

        public init(version: String?, accelerators: String?) {
            self.version = version
            self.accelerators = accelerators
        }
    }

    /// The installation to use, before validation.
    public static func select(_ inputs: Inputs) throws -> QEMUInstallation {
        if inputs.allowEnvironmentOverride, let path = inputs.environment[environmentKey], !path.isEmpty {
            return QEMUInstallation(root: URL(fileURLWithPath: path, isDirectory: true), source: .environment)
        }
        if let override = inputs.userOverride {
            guard !inputs.policyBoundLaunch else { throw QEMUPathError.overrideNeedsApp(path: override.path) }
            return QEMUInstallation(root: override, source: .userOverride)
        }
        return QEMUInstallation(root: inputs.runtimeCopy, source: .runtimeCopy)
    }

    /// `select` followed by `validate`.
    public static func resolve(_ inputs: Inputs, probe: (URL) -> Probe = QEMUPaths.probe) throws -> QEMUInstallation {
        let installation = try select(inputs)
        try validate(installation, probe: probe)
        return installation
    }

    /// The binary runs, is at least `minimumMajor`, and supports HVF (TCG is never used).
    public static func validate(_ installation: QEMUInstallation, probe: (URL) -> Probe = QEMUPaths.probe) throws {
        let path = installation.root.path
        guard FileManager.default.isExecutableFile(atPath: installation.qemuSystem.path) else {
            throw QEMUPathError.invalid(path: path, reason: "no executable bin/qemu-system-aarch64")
        }
        let result = probe(installation.qemuSystem)
        guard let version = result.version, let major = majorVersion(version) else {
            throw QEMUPathError.invalid(path: path, reason: "qemu-system-aarch64 --version failed")
        }
        guard major >= minimumMajor else {
            throw QEMUPathError.invalid(path: path, reason: "QEMU \(major) is older than \(minimumMajor)")
        }
        guard let accelerators = result.accelerators, acceleratorList(accelerators).contains("hvf") else {
            throw QEMUPathError.invalid(path: path, reason: "built without HVF")
        }
    }

    /// The major version in "QEMU emulator version 11.1.2 (…)".
    static func majorVersion(_ output: String) -> Int? {
        guard let match = output.firstMatch(of: /version (\d+)\.\d+/) else { return nil }
        return Int(match.1)
    }

    /// The names under "Accelerators supported in QEMU binary:".
    static func acceleratorList(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).dropFirst().map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Runs the two probe commands (10 s each).
    public static func probe(_ qemuSystem: URL) -> Probe {
        Probe(version: run(qemuSystem, ["--version"]), accelerators: run(qemuSystem, ["-accel", "help"]))
    }

    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vmpane-qemu-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        guard let child = try? ChildSpawner.spawn(executable, .init(arguments: arguments, environment: [:], logFile: output)) else {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while true {
            let reaped = waitpid(child.pid, &status, WNOHANG)
            if reaped == child.pid { break }
            if reaped == -1 && errno != EINTR { return nil }
            guard Date() < deadline else {
                kill(child.pid, SIGKILL)
                waitpid(child.pid, &status, 0)
                return nil
            }
            usleep(10_000)
        }
        guard status == 0 else { return nil }
        return try? String(contentsOf: output, encoding: .utf8)
    }
}
