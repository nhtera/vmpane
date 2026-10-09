import VMPaneControl
import VMPaneCore
import VMPaneHost

/// Shared SwiftUI views and view models for the app and the helper.
public enum UIInfo {
    /// Window-title format for a helper window ("<VM name> — VMPane").
    public static func windowTitle(vmName: String) -> String {
        "\(vmName) — VMPane"
    }
}
