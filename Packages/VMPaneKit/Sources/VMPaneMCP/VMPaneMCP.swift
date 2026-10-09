import VMPaneControl
import VMPaneCore

/// MCP server exposed by `vmpane mcp` (stdio). Hand-rolled, dual-era protocol support
/// (see docs/adr/0002-mcp-sdk.md).
public enum MCPProtocol {
    /// Stateless revision (per-request `_meta`) first, then the handshake-based revisions.
    public static let supportedVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
}
