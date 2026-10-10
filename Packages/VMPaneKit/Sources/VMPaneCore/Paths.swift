import Foundation

/// File-system locations used by the app, the helper and the CLI.
/// Everything lives under `~/Library/Application Support/VMPane/` unless a test passes another root.
public struct VMPanePaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/VMPane`, or `$VMPANE_SUPPORT_DIR` when set (integration tests use
    /// it so they never touch the user's real library).
    public static func standard() -> VMPanePaths {
        if let override = ProcessInfo.processInfo.environment["VMPANE_SUPPORT_DIR"], !override.isEmpty {
            return VMPanePaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VMPanePaths(root: support.appendingPathComponent("VMPane", isDirectory: true))
    }

    public var defaultLibrary: URL { root.appendingPathComponent("VMs", isDirectory: true) }
    public var libraryIndex: URL { root.appendingPathComponent("library.json") }
    public var runDirectory: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var runtimeDirectory: URL { root.appendingPathComponent("runtime", isDirectory: true) }

    public func runtime(version: String) -> URL {
        runtimeDirectory.appendingPathComponent(version, isDirectory: true)
    }

    /// `run/<sid>.sock`: the helper's control socket.
    public func socket(for sid: ShortID) -> URL { runDirectory.appendingPathComponent("\(sid).sock") }
    /// `run/<sid>.pid`: `{pid, startTime, runtimeVersion}` of the helper.
    public func pidFile(for sid: ShortID) -> URL { runDirectory.appendingPathComponent("\(sid).pid") }
    /// `run/<sid>.children`: one child record per line.
    public func childrenFile(for sid: ShortID) -> URL { runDirectory.appendingPathComponent("\(sid).children") }
    /// `run/<sid>/`: per-VM sockets of child processes (QEMU, swtpm).
    public func childDirectory(for sid: ShortID) -> URL { runDirectory.appendingPathComponent(sid.rawValue, isDirectory: true) }
}

/// Where to bind or connect a Unix socket, given `sun_path`'s 104-byte limit (103 + NUL).
public enum UnixSocketAddress: Equatable, Sendable {
    /// The absolute path fits.
    case absolute(String)
    /// Too long: `chdir` to `directory` (or use `bindat`/`connectat`) and use the short `name`.
    case relative(directory: String, name: String)

    /// Longest absolute path used as is. Leaves headroom below the hard limit of 103 bytes.
    public static let maxAbsoluteLength = 100

    public init(_ url: URL) {
        let path = url.path
        if path.utf8.count <= Self.maxAbsoluteLength {
            self = .absolute(path)
        } else {
            self = .relative(directory: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
    }
}
