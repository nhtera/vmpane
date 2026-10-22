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
        /// `cloudImage`: a distribution's cloud image (qcow2), set up with cloud-init instead of an installer. Absent:
        /// an installer ISO (or a macOS restore image).
        public var kind: String?
        /// Cloud images: `ubuntu`, `debian` or `fedora` (what the seed is written for).
        public var distro: String?

        public var isCloudImage: Bool { kind == "cloudImage" }

        public init(
            id: String, name: String, version: String, build: String? = nil, url: URL, sha256: String, sizeBytes: Int64,
            kind: String? = nil, distro: String? = nil
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.build = build
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.kind = kind
            self.distro = distro
        }

        /// The name with its version once ("macOS Sequoia 15.6.1" already carries it; "Ubuntu" does not).
        public var title: String { name.hasSuffix(version) ? name : "\(name) \(version)" }
    }

    public var schemaVersion: Int
    public var images: [Image]

    /// macOS restore images. The primary macOS path: `VZMacOSRestoreImage.fetchLatestSupported` fails
    /// on macOS 15 hosts (Apple's catalog lists only macOS 27), so VMPane ships its own list.
    public static func macOS() throws -> ImageCatalog { try load("macos-catalog") }
    /// Linux arm64 cloud images and installer ISOs (`scripts/refresh-linux-catalog.sh` pins the cloud images).
    public static func linux() throws -> ImageCatalog { try load("linux-catalog") }

    static func load(_ name: String) throws -> ImageCatalog {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try CanonicalJSON.decoder().decode(ImageCatalog.self, from: Data(contentsOf: url))
    }
}
