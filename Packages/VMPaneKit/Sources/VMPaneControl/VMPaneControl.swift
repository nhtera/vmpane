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
}
