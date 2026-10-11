import Darwin
import Foundation

/// A shared folder as the guest may reach it: every path is resolved inside `root`, one component at a time
/// with `openat` and `O_NOFOLLOW`, so `..`, absolute paths and symlinks (planted by the guest or already there)
/// never lead outside it (Red Team #13). Symlinks inside the share are not followed at all: they are neither
/// listed nor opened.
public struct PathJail: Sendable {
    public enum Failure: Error, Equatable {
        case badPath
        case notFound
        case readOnly
        case system(Int32)
    }

    public let root: URL
    public let readOnly: Bool

    public init(root: URL, readOnly: Bool) {
        self.root = root.standardizedFileURL
        self.readOnly = readOnly
    }

    /// The components of a share-relative path: each a plain name (no "/", ".", "..", NUL), NFC.
    public static func components(_ path: String) throws(Failure) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(part).precomposedStringWithCanonicalMapping
            guard name != ".", name != "..", !name.contains("\0"), !name.contains("\\"), name.utf8.count <= 255 else {
                throw Failure.badPath
            }
            parts.append(name)
        }
        return parts
    }

    /// An open descriptor of the folder holding `parts.last` (the root for an empty path), walked without links.
    /// The caller closes it.
    public func openParent(_ parts: [String]) throws(Failure) -> Int32 {
        try openDirectory(Array(parts.dropLast()))
    }

    /// An open descriptor of the folder at `parts`. The caller closes it.
    public func openDirectory(_ parts: [String]) throws(Failure) -> Int32 {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.system(errno) }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { throw code == ENOENT ? Failure.notFound : Failure.system(code) }
            fd = next
        }
        return fd
    }

    /// `lstat` of `name` in folder `directory`; symlinks count as missing.
    public static func info(_ directory: Int32, _ name: String) -> stat? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        return info
    }

    /// Opens file `parts` for reading (never through a link).
    public func openFile(_ parts: [String]) throws(Failure) -> Int32 {
        guard let name = parts.last else { throw Failure.badPath }
        let directory = try openParent(parts)
        defer { close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT || errno == ELOOP ? Failure.notFound : Failure.system(errno) }
        return fd
    }

    /// Throws `readOnly` for a read-only share.
    public func checkWritable() throws(Failure) {
        if readOnly { throw Failure.readOnly }
    }
}
