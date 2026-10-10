import Darwin
import Foundation

public enum DiskImageError: Error, Equatable, Sendable {
    /// Disks only grow: shrinking would cut off guest data.
    case shrinkNotAllowed(current: UInt64, requested: UInt64)
}

/// Raw sparse disk images (VMPane's only disk format).
public enum DiskImage {
    /// Creates a sparse raw image of `sizeBytes` (0600). Fails if the file exists.
    public static func createRaw(at url: URL, sizeBytes: UInt64) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError.current() }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            let error = POSIXError.current()
            unlink(url.path)
            throw error
        }
        try DurableWrite.fullSync(fd)
    }

    /// Grows the image to `sizeBytes`; the guest extends its partition itself.
    public static func grow(_ url: URL, to sizeBytes: UInt64) throws {
        let current = try logicalSize(url)
        guard sizeBytes >= current else { throw DiskImageError.shrinkNotAllowed(current: current, requested: sizeBytes) }
        guard sizeBytes > current else { return }
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else { throw POSIXError.current() }
        try DurableWrite.fullSync(fd)
    }

    public static func logicalSize(_ url: URL) throws -> UInt64 {
        try UInt64(stat(url).st_size)
    }

    /// Bytes allocated on disk, including blocks shared with clones (snapshots).
    public static func allocatedBytes(_ url: URL) throws -> UInt64 {
        try UInt64(stat(url).st_blocks) * 512
    }

    /// Bytes that belong to this file alone (not shared with any clone): what deleting it would free.
    /// nil where the file system does not report it; show `allocatedBytes` as "up to" then.
    public static func privateBytes(_ url: URL) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // Returned layout: u_int32_t length, then off_t private size.
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(url.path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        let length = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard length >= 4 + 8 else { return nil }
        let size = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return size >= 0 ? UInt64(size) : nil
    }

    private static func stat(_ url: URL) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError.current() }
        return info
    }
}
