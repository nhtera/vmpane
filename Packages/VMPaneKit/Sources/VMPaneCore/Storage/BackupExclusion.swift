import Darwin
import Foundation

/// Saved RAM state (suspend files, live snapshots' `state/`) can be as large as the guest's memory and is
/// worthless on another Mac; users can keep it out of Time Machine (Preferences, Phase 08).
///
/// Written as the extended attribute Time Machine reads (what `tmutil addexclusion` sets), not through
/// `URLResourceValues.isExcludedFromBackup`, whose cached values made writes unreliable.
public enum BackupExclusion {
    static let attribute = "com.apple.metadata:com_apple_backup_excludeItem"
    /// Binary plist of the string "com.apple.backupd".
    static let value: [UInt8] = Array(
        (try? PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0)) ?? Data())

    /// Sets or clears the exclusion on every RAM-state directory of the bundle.
    public static func apply(_ excluded: Bool, to bundle: VMBundle) throws {
        var targets = [bundle.stateDirectory]
        let snapshots = (try? FileManager.default.contentsOfDirectory(at: bundle.snapshotsDirectory, includingPropertiesForKeys: nil)) ?? []
        targets += snapshots.map { $0.appendingPathComponent("state", isDirectory: true) }
        for url in targets where FileManager.default.fileExists(atPath: url.path) {
            try set(excluded, url)
        }
    }

    public static func isExcluded(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    private static func set(_ excluded: Bool, _ url: URL) throws {
        if excluded {
            let result = value.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            guard result == 0 else { throw POSIXError.current() }
        } else if removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw POSIXError.current()
        }
    }
}
