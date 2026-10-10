import Darwin
import Foundation

public enum CloneError: Error, Equatable, Sendable {
    /// Source and destination are not on the same clone-capable (APFS) volume. The UI offers a full copy.
    case unsupported
}

/// Copy-on-write copies via `clonefile(2)`: instant and initially free on APFS. Used for snapshots,
/// restores and clones.
public enum CloneFile {
    /// Whether the volume holding `url` (or its nearest existing ancestor) supports file cloning.
    public static func volumeSupportsCloning(_ url: URL) -> Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        return (try? probe.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) == true
    }

    /// Clones a file or a directory tree. Symlinks are cloned as links, never followed. Fails if `destination` exists.
    public static func clone(_ source: URL, to destination: URL) throws {
        guard volumeSupportsCloning(source), volumeSupportsCloning(destination.deletingLastPathComponent()) else {
            throw CloneError.unsupported
        }
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            if errno == ENOTSUP || errno == EXDEV { throw CloneError.unsupported }
            throw POSIXError.current()
        }
    }
}
