import Darwin
import Foundation

/// Crash-safe file replacement: write a temp file in the same directory, `F_FULLFSYNC` it, rename it over
/// the target, then fsync the directory. A reader sees either the old or the new file, never a torn one.
public enum DurableWrite {
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw POSIXError.current() }
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }  // empty data
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError.current()
                    }
                    offset += written
                }
            }
            try fullSync(fd)
            close(fd)
        } catch {
            close(fd)
            unlink(temp.path)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let error = POSIXError.current()
            unlink(temp.path)
            throw error
        }
        try syncDirectory(directory)
    }

    /// `F_FULLFSYNC` (flushes the drive cache, unlike `fsync` on macOS); falls back to `fsync` where
    /// the file system does not support it.
    public static func fullSync(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw POSIXError.current() }
    }

    /// `fsync`s every file and directory under `url`, then one `F_FULLFSYNC` barrier. On APFS a full sync
    /// flushes the whole device, so one barrier after per-file syncs orders everything before it.
    public static func syncTree(_ url: URL) throws {
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                let fd = open(item.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { continue }  // e.g. a symlink
                fsync(fd)
                close(fd)
            }
        }
        try syncDirectory(url)
    }

    /// Persists a directory's entries (renames, creations) by syncing the directory itself.
    public static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        defer { close(fd) }
        try fullSync(fd)
    }
}

extension POSIXError {
    /// The error for the current `errno`.
    public static func current() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
