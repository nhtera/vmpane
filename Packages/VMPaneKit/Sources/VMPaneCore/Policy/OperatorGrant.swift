import CryptoKit
import Darwin
import Foundation

/// The user's permission for their own interactive `vmpane` use to act as `operator` (decided at admin, never
/// `uiOnly`; Validation 2026-10-07): a file in VMPane's folder tagged with the policy key, made by
/// `vmpane operator grant` from a terminal (or the app), removed by `revoke`. Without it every CLI process is
/// policy-bound like an agent. Touch ID is not required in v1: an agent able to fake a terminal has a host
/// shell, which the threat model does not constrain (`docs/security-model.md`).
public enum OperatorGrant {
    static func url(_ paths: VMPanePaths) -> URL { paths.root.appendingPathComponent("operator.grant") }

    private static func message(uid: uid_t) -> Data { Data("vmpane operator grant\nuid \(uid)".utf8) }

    public static func grant(paths: VMPanePaths, uid: uid_t = getuid()) throws {
        guard let key = PolicyKeyFile(paths: paths).key(create: true) else { throw POSIXError(.EACCES) }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: message(uid: uid), using: key)).base64EncodedString()
        try DurableWrite.write(Data(tag.utf8), to: url(paths))
        chmod(url(paths).path, 0o600)
    }

    public static func revoke(paths: VMPanePaths) throws {
        do {
            try FileManager.default.removeItem(at: url(paths))
        } catch CocoaError.fileNoSuchFile {}
    }

    public static func isGranted(paths: VMPanePaths, uid: uid_t = getuid()) -> Bool {
        guard let key = PolicyKeyFile(paths: paths).key(create: false), let text = try? String(contentsOf: url(paths), encoding: .utf8),
            let tag = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message(uid: uid), using: key)
    }
}

/// Whether this process looks like a person at a terminal rather than an agent: stdin and stdout are terminals
/// and no ancestor is `vmpane mcp`.
public enum InteractiveSession {
    public static func isInteractive() -> Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && !underMCP()
    }

    /// Some ancestor's command line is `vmpane mcp …`.
    static func underMCP() -> Bool {
        var pid = getppid()
        for _ in 0..<64 where pid > 1 {
            let arguments = self.arguments(of: pid)
            if arguments.count >= 2, (arguments[0] as NSString).lastPathComponent == "vmpane", arguments[1] == "mcp" { return true }
            guard let parent = parentPID(of: pid), parent != pid else { return false }
            pid = parent
        }
        return false
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// A process's argv (KERN_PROCARGS2: argc, the executable path, then the arguments); empty if unreadable.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // the executable path
        while index < size, buffer[index] == 0 { index += 1 }  // its padding
        var arguments: [String] = []
        while arguments.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(bytes: buffer[start..<index], encoding: .utf8) ?? "")
            index += 1
        }
        return arguments
    }
}
