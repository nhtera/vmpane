import Foundation

public struct InsufficientSpace: Error, Equatable, Sendable {
    public let requiredBytes: UInt64
    public let availableBytes: UInt64

    public init(requiredBytes: UInt64, availableBytes: UInt64) {
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
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
