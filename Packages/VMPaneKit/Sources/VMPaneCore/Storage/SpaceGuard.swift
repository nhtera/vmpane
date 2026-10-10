import Foundation

public struct InsufficientSpace: Error, Equatable, Sendable {
    public let requiredBytes: UInt64
    public let availableBytes: UInt64
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

    public static func check(
        memoryBytes: UInt64, at url: URL,
        available: (URL) throws -> UInt64 = SpaceGuard.availableBytes
    ) throws {
        let required = requiredBytes(memoryBytes: memoryBytes)
        let free = try available(url)
        if free < required { throw InsufficientSpace(requiredBytes: required, availableBytes: free) }
    }
}
