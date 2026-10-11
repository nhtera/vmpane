import CryptoKit
import Foundation

/// The agent kill switch (Red Team #1): one tagged file, `killswitch`, in VMPane's folder, which every helper
/// watches and reads at launch, so it works with or without the app running. Anyone may engage it (`vmpane mcp
/// kill`, the menu bar, `mcp.disableAll`); only the app releases it (`mcp.enableAll`). It is written released when
/// the policy key is made; after that a missing file or a bad tag counts as engaged, so removing or editing the
/// file can only switch agents off.
public enum KillSwitch {
    public static func url(_ paths: VMPanePaths) -> URL { paths.root.appendingPathComponent("killswitch") }

    private static func message(engaged: Bool) -> Data { Data("vmpane kill switch\n\(engaged ? "engaged" : "released")".utf8) }

    /// Whether agents are stopped. Without a policy key nothing can be raised above `off` anyway (no tag
    /// checks out), so the switch reads as released then.
    public static func isEngaged(paths: VMPanePaths) -> Bool {
        guard let key = PolicyKeyFile(paths: paths).key(create: false) else { return false }
        guard let text = try? String(contentsOf: url(paths), encoding: .utf8) else { return true }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == 2, let tag = Data(base64Encoded: lines[1]) else { return true }
        let engaged = lines[0] != "released"
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message(engaged: engaged), using: key) else { return true }
        return engaged
    }

    /// Stops every agent (any client may).
    public static func engage(paths: VMPanePaths) throws { try write(engaged: true, paths: paths) }

    /// Lets agents act again within their VMs' policies (the app only: `mcp.enableAll` is UI-only).
    public static func release(paths: VMPanePaths) throws { try write(engaged: false, paths: paths) }

    static func write(engaged: Bool, paths: VMPanePaths) throws {
        guard let key = PolicyKeyFile(paths: paths).key(create: true) else { throw POSIXError(.EACCES) }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: message(engaged: engaged), using: key)).base64EncodedString()
        try DurableWrite.write(Data("\(engaged ? "engaged" : "released")\n\(tag)\n".utf8), to: url(paths))
    }
}
