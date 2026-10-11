import CryptoKit
import Darwin
import Foundation

/// Where the policy key lives. v1 keeps it in a 0600 file in VMPane's support folder: the threat model is an AI
/// agent acting through VMPane's interfaces, not one with a general shell (which could edit `config.json` anyway),
/// and a file works for helpers started from SSH or while the Mac is locked, where the login keychain does not.
/// A keychain provider can replace it (S4 showed the trusted-application ACL working). `docs/security-model.md`.
public protocol PolicyKeyProvider: Sendable {
    /// The key; with `create`, made on first use.
    func key(create: Bool) -> SymmetricKey?
}

public struct PolicyKeyFile: PolicyKeyProvider {
    public let url: URL
    let paths: VMPanePaths

    public init(paths: VMPanePaths) {
        self.paths = paths
        url = paths.root.appendingPathComponent("policy.key")
    }

    public func key(create: Bool) -> SymmetricKey? {
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        guard create else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = SymmetricKey(size: .bits256)
        // Written whole beside it, then linked in place (fails if someone made it meanwhile): a reader never
        // sees a short key.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".policy.key.\(UUID().uuidString)")
        defer { unlink(temporary.path) }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let written = fresh.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == 32, synced else { return nil }
        if link(temporary.path, url.path) == 0 {
            // From now on a missing kill-switch file means engaged: start released.
            try? KillSwitch.write(engaged: false, paths: paths)
            return fresh
        }
        // Someone else made it meanwhile.
        return (try? Data(contentsOf: url)).flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
    }
}

/// The integrity tag on a VM's agent policy (Red Team #1): `mcp.tag` = HMAC-SHA256 over the VM id, the `mcp`
/// settings and `clipboard.allowWithAgents`, written only by VMPane's own code when the UI changes them. A level
/// above `off` counts only with a valid tag; a hand-edited policy reads as `off`, and the UI says so.
public enum PolicyIntegrity {
    /// The tag for `config`'s current policy settings.
    public static func tag(_ config: VMConfigV1, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message(config).utf8), using: key)).base64EncodedString()
    }

    /// `config` with its policy tagged.
    public static func signed(_ config: VMConfigV1, key: SymmetricKey) -> VMConfigV1 {
        var config = config
        config.mcp.tag = tag(config, key: key)
        return config
    }

    public struct Effective: Equatable, Sendable {
        public let level: PolicyLevel
        /// The saved level is above `off` but its tag does not check out (edited outside VMPane, or no key).
        public let tampered: Bool
        /// Agents may use the clipboard (only with a valid tag).
        public let clipboardAllowWithAgents: Bool
    }

    /// The policy that applies: the saved one when its tag checks out, else `off`.
    public static func effective(_ config: VMConfigV1, key: SymmetricKey?) -> Effective {
        let raised = config.mcp.policy != .off || config.clipboard.allowWithAgents
        guard raised else { return Effective(level: .off, tampered: false, clipboardAllowWithAgents: false) }
        guard let key, let tag = config.mcp.tag, let given = Data(base64Encoded: tag),
            HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data(message(config).utf8), using: key)
        else { return Effective(level: .off, tampered: true, clipboardAllowWithAgents: false) }
        return Effective(level: config.mcp.policy, tampered: false, clipboardAllowWithAgents: config.clipboard.allowWithAgents)
    }

    private static func message(_ config: VMConfigV1) -> String {
        let mcp = config.mcp
        return [
            config.id.uuidString.lowercased(), mcp.policy.rawValue, String(mcp.confirmExec), String(mcp.autoSnapshot),
            String(mcp.auditTypedText), String(config.clipboard.allowWithAgents),
        ].joined(separator: "\n")
    }
}
