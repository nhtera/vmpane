import AppKit

/// Sharing a folder gives the guest (and whatever runs in it) read and write access to it. Some folders are
/// too much to hand over without a second thought: the home or root folder, and folders that hold keys.
@MainActor
public enum ShareWarning {
    /// Why sharing `url` deserves a warning, if it does.
    public static func reason(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = url.standardizedFileURL.path
        if path == "/" { return "This is the whole disk." }
        if path == home.standardizedFileURL.path { return "This is your whole home folder, including your keys and passwords." }
        let sensitive = [".ssh", ".gnupg", ".aws", "Library/Keychains", "Library"]
        for name in sensitive {
            let folder = home.appendingPathComponent(name).standardizedFileURL.path
            if path == folder || path.hasPrefix(folder + "/") { return "It holds keys or app data (\(name))." }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent(".ssh").path) { return "It contains a .ssh folder with keys." }
        return nil
    }

    /// Asks before sharing a risky folder; true to go ahead.
    public static func confirm(_ url: URL) -> Bool {
        guard let reason = reason(for: url) else { return true }
        let alert = NSAlert()
        alert.messageText = "Share “\(url.lastPathComponent)” with the VM?"
        alert.informativeText = "\(reason) The VM, and anything running in it, can read and change what you share."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Share Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
