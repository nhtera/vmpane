import Foundation

/// Preferences the app sets and its helpers read (the app's defaults domain, shared by name).
public enum SharedPreferences {
    public static let suite = "app.vmpane.mac"

    static var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    static let excludeRAMKey = "excludeRAMSnapshotsFromBackup"

    /// Live snapshots' saved memory stays out of Time Machine backups (it can hold passwords and keys). On by
    /// default.
    public static var excludeRAMSnapshotsFromBackup: Bool {
        get { defaults.object(forKey: excludeRAMKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: excludeRAMKey) }
    }

    /// Marks `url` (and so everything in it) as excluded from backups.
    public static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
