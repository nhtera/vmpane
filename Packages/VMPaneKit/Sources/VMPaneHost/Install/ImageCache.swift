import Foundation

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

    /// The verified local copy, downloading (or resuming) it when needed.
    public func ensure(
        _ image: ImageCatalog.Image, session: URLSession = .shared,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        let file = file(for: image)
        if FileManager.default.fileExists(atPath: file.path), try Downloader.sha256(of: file) == image.sha256 {
            return file
        }
        return try await Downloader.download(image.url, to: file, sha256: image.sha256, session: session, progress: progress)
    }
}
