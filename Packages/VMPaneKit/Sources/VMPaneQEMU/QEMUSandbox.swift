import Darwin
import Foundation

/// QEMU and swtpm run under deny-by-default sandbox profiles (`Sandbox/*.sb`, resources of this module),
/// applied with `sandbox-exec`: a guest that takes over QEMU reaches only its own bundle and run directory
/// (Gate 00 S4, Red Team #6).
public enum QEMUSandbox {
    public enum Program: String, Sendable, CaseIterable {
        case qemu, swtpm
    }

    public static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    public static func profile(_ program: Program) throws -> URL {
        guard let url = Bundle.module.url(forResource: program.rawValue, withExtension: "sb", subdirectory: "Sandbox") else {
            throw QEMUConfigError.missingFile("Sandbox/\(program.rawValue).sb")
        }
        return url
    }

    /// The `sandbox-exec` arguments that run `executable arguments…` under `program`'s profile. Sandbox rules
    /// match resolved paths, so every parameter is a real path (`/tmp` is a symlink to `/private/tmp`).
    public static func arguments(_ program: Program, executable: URL, arguments: [String], layout: QEMULayout) throws -> [String] {
        [
            "-f", try profile(program).path,
            "-D", "BUNDLE=\(try realPath(layout.bundle.url))",
            "-D", "RUNDIR=\(try realPath(layout.runDirectory))",
            "-D", "RUNTIME=\(try realPath(layout.installation.root))",
            executable.path,
        ] + arguments
    }

    static func realPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw POSIXError.current() }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
