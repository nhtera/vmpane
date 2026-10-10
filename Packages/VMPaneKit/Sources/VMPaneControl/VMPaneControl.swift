import VMPaneCore

/// Control protocol between app/CLI/MCP and the per-VM helper (JSON-RPC 2.0 over a Unix socket).
public enum ControlProtocol {
    /// Current protocol version and the oldest version this build still speaks.
    public static let version = 1
    public static let minimumVersion = 1

    /// Whether a peer advertising `peerVersion` can talk to this build.
    public static func isCompatible(peerVersion: Int) -> Bool {
        peerVersion >= minimumVersion
    }

    /// The highest version both sides speak, or nil if their ranges do not overlap.
    public static func negotiate(peerVersion: Int, peerMinimum: Int) -> Int? {
        let version = min(version, peerVersion)
        return version >= max(minimumVersion, peerMinimum) ? version : nil
    }
}
