import Darwin
import Foundation
import VMPaneCore

public enum UnattendMediaError: Error, Equatable, Sendable {
    case imageToolFailed(Int32)
}

/// `install/unattend.iso`: a small ISO with `autounattend.xml` at its root, attached as removable media;
/// Windows Setup scans removable-media roots for it. It holds the account password in plain text (Windows
/// needs it), so it is 0600, lives outside `current/` (never in a snapshot or clone) and `remove` deletes it
/// on every way the install ends.
public enum UnattendMedia {
    public static let volumeName = "VMPANE_UNATTEND"
    public static let fileName = "unattend.iso"

    public static func url(in bundle: VMBundle) -> URL { bundle.installDirectory.appendingPathComponent(fileName) }

    /// Builds the image from `xml`, replacing an older one.
    @discardableResult
    public static func build(_ xml: String, in bundle: VMBundle) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.installDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Staged in the install directory itself (0700), never in a shared temporary directory.
        let staging = bundle.installDirectory.appendingPathComponent(".unattend-\(UUID().uuidString)", isDirectory: true)
        // hdiutil appends ".iso" to an output name without it.
        let partial = bundle.installDirectory.appendingPathComponent(".unattend-partial-\(UUID().uuidString).iso")
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: partial)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try DurableWrite.write(Data(xml.utf8), to: staging.appendingPathComponent("autounattend.xml"))
        let tool = try ChildSpawner.spawn(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            .init(arguments: [
                "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", volumeName, "-o", partial.path, staging.path,
            ]))
        var status: Int32 = 0
        waitpid(tool.pid, &status, 0)
        guard status == 0 else { throw UnattendMediaError.imageToolFailed(status) }
        guard chmod(partial.path, 0o600) == 0 else { throw POSIXError.current() }
        let target = url(in: bundle)
        guard rename(partial.path, target.path) == 0 else { throw POSIXError.current() }
        try DurableWrite.syncDirectory(bundle.installDirectory)
        return target
    }

    /// Deletes the image (and any half-built one). Safe to call when there is none.
    public static func remove(from bundle: VMBundle) {
        let fm = FileManager.default
        try? fm.removeItem(at: url(in: bundle))
        for entry in (try? fm.contentsOfDirectory(atPath: bundle.installDirectory.path)) ?? []
        where entry.hasPrefix(".unattend-") {
            try? fm.removeItem(at: bundle.installDirectory.appendingPathComponent(entry))
        }
        try? DurableWrite.syncDirectory(bundle.installDirectory)
    }
}
