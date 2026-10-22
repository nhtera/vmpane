import Foundation
import VMPaneCore

/// Downloaded installation images, in `~/Library/Caches/app.vmpane.mac/IPSW|ISO/`.
public struct ImageCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard(_ kind: String) -> ImageCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ImageCache(directory: caches.appendingPathComponent("app.vmpane.mac/\(kind)", isDirectory: true))
    }

    public static var ipsw: ImageCache { standard("IPSW") }
    public static var iso: ImageCache { standard("ISO") }

    public func file(for image: ImageCatalog.Image) -> URL {
        directory.appendingPathComponent(image.url.lastPathComponent)
    }

    /// Whether `image` was downloaded already (its checksum is verified when it is used).
    public func has(_ image: ImageCatalog.Image) -> Bool {
        FileManager.default.fileExists(atPath: file(for: image).path)
    }

    /// The verified local copy, downloading (or resuming) it when needed. One call per file at a time in this
    /// process: two creates of one image would append to the same partial file, so the second waits, then finds it.
    public func ensure(
        _ image: ImageCatalog.Image, session: URLSession = .shared,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        let file = file(for: image)
        try await FileGate.shared.enter(file.path)
        do {
            let ready: URL
            if FileManager.default.fileExists(atPath: file.path),
                try await Blocking.run({ try Downloader.sha256(of: file) }) == image.sha256
            {
                ready = file
            } else {
                ready = try await Downloader.download(image.url, to: file, sha256: image.sha256, session: session, progress: progress)
            }
            await FileGate.shared.leave(file.path)
            return ready
        } catch {
            await FileGate.shared.leave(file.path)
            throw error
        }
    }
}

/// One holder per key at a time; the others wait their turn, in order. A waiter whose task is cancelled leaves the
/// queue at once (`CancellationError`).
actor FileGate {
    static let shared = FileGate()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var held: Set<String> = []
    private var waiting: [String: [Waiter]] = [:]

    func enter(_ key: String) async throws {
        guard held.contains(key) else {
            held.insert(key)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[key, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id, key) }
        }
    }

    /// Hands the key to the next waiter, or frees it.
    func leave(_ key: String) {
        guard var queue = waiting[key], !queue.isEmpty else {
            held.remove(key)
            waiting[key] = nil
            return
        }
        let next = queue.removeFirst()
        waiting[key] = queue.isEmpty ? nil : queue
        next.continuation.resume()
    }

    private func cancel(_ id: UUID, _ key: String) {
        guard let index = waiting[key]?.firstIndex(where: { $0.id == id }), let waiter = waiting[key]?.remove(at: index) else { return }
        if waiting[key]?.isEmpty == true { waiting[key] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
