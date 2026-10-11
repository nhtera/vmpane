import Foundation

/// VMPane's MCP tools (20; one action each), in the order `tools/list` gives them.
public enum VMPaneTools {
    /// `exchange`: the Mac-side folder for file transfers (`~/VMPane Exchange`).
    public static func registry(_ access: VMAccess, exchange: URL) -> ToolRegistry {
        ToolRegistry(VMTools.all(access) + InputTools.all(access) + GuestTools.all(access, exchange: exchange))
    }
}
