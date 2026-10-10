import Foundation
import VMPaneCore

/// A curated, sha256-pinned list of installation images shipped with the app (refreshed per release).
public struct ImageCatalog: Codable, Sendable, Equatable {
    public struct Image: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var version: String
        public var build: String?
        public var url: URL
        public var sha256: String
        public var sizeBytes: Int64
    }

    public var schemaVersion: Int
    public var images: [Image]

    /// macOS restore images. The primary macOS path: `VZMacOSRestoreImage.fetchLatestSupported` fails
    /// on macOS 15 hosts (Apple's catalog lists only macOS 27), so VMPane ships its own list.
    public static func macOS() throws -> ImageCatalog { try load("macos-catalog") }
    /// Linux arm64 installer ISOs.
    public static func linux() throws -> ImageCatalog { try load("linux-catalog") }

    static func load(_ name: String) throws -> ImageCatalog {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try CanonicalJSON.decoder().decode(ImageCatalog.self, from: Data(contentsOf: url))
    }
}
