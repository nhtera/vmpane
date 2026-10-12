import Foundation

public struct InsufficientSpace: Error, Equatable, Sendable, CustomStringConvertible {
    public let requiredBytes: UInt64
    public let availableBytes: UInt64

    public init(requiredBytes: UInt64, availableBytes: UInt64) {
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    public var description: String {
        let size = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
        return "not enough free disk space: this needs \(size(requiredBytes)), \(size(availableBytes)) is free"
    }
}

/// Refuses operations that write RAM state (suspend, live snapshot) when the volume is nearly full:
/// a half-written state file on a full disk can take the whole VM down with it.
public enum SpaceGuard {
    public static let reserveBytes: UInt64 = 5 << 30

    /// Free space needed to save `memoryBytes` of RAM: RAM × 1.1 + 5 GiB.
    public static func requiredBytes(memoryBytes: UInt64) -> UInt64 {
        memoryBytes + memoryBytes / 10 + reserveBytes
    }

    public static func availableBytes(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return UInt64(important) }
        return UInt64(values.volumeAvailableCapacity ?? 0)
    }

    /// Bytes a write can use right now (`statfs`), without the purgeable space macOS would free on demand:
    /// what a running VM's disk growth can rely on.
    public static func freeBytes(at url: URL) throws -> UInt64 {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw POSIXError.current() }
        return UInt64(info.f_bavail) * UInt64(info.f_bsize)
    }

    /// Refuses to begin writing `bytes` (an install) at `url` unless they fit with `reserveBytes` to spare, so a
    /// long write does not leave the Mac's disk full. `url` may not exist yet: its nearest existing folder is measured.
    public static func require(
        _ bytes: UInt64, at url: URL,
        available: (URL) throws -> UInt64 = SpaceGuard.freeBytes
    ) throws {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let required = bytes + reserveBytes
        let free = try available(probe)
        if free < required { throw InsufficientSpace(requiredBytes: required, availableBytes: free) }
    }

    /// Uses `freeBytes` (no purgeable space), the same measure the QEMU disk-full watchdog pauses on, so a
    /// save that passes this check does not itself trip the watchdog.
    public static func check(
        memoryBytes: UInt64, at url: URL,
        available: (URL) throws -> UInt64 = SpaceGuard.freeBytes
    ) throws {
        let required = requiredBytes(memoryBytes: memoryBytes)
        let free = try available(url)
        if free < required { throw InsufficientSpace(requiredBytes: required, availableBytes: free) }
    }
}
