import Foundation

/// Runs blocking work (reaping waits, file-system syncs, snapshot I/O) on a dedicated queue instead of
/// Swift's cooperative thread pool, which must never be blocked for seconds.
public enum Blocking {
    private static let queue = DispatchQueue(label: "app.vmpane.blocking", qos: .utility, attributes: .concurrent)

    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
