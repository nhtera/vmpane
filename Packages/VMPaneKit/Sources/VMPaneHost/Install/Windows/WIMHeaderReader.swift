import Foundation

/// One image of a Windows install image (`sources/install.wim|esd`).
public struct WindowsImage: Equatable, Sendable {
    public var index: Int
    public var name: String
    /// `ARCH` of the image: 12 is ARM64 (9 x64, 0 x86).
    public var architecture: Int?
    public var build: Int?

    public var isARM64: Bool { architecture == 12 }
    /// Windows 11 is build 22000 and later.
    public var isWindows11: Bool { (build ?? 0) >= 22_000 }
}

public enum WIMHeaderError: Error, Equatable, Sendable {
    case notAWIM
    /// The image list is compressed or does not fit the file.
    case unreadableImageList
}

/// Reads the image list of a WIM/ESD file: its header (208 bytes, magic `MSWIM`) points at an uncompressed
/// UTF-16LE XML resource describing every image. Only that resource is read, never the image data, and both
/// are untrusted input (sizes are bounded, the XML is parsed without external entities).
public enum WIMHeaderReader {
    static let headerSize = 208
    /// The XML resource of a real install image is a few KB per edition.
    static let maxXMLBytes = 4 << 20

    public static func images(of file: URL) throws -> [WindowsImage] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: headerSize), header.count == headerSize,
            header.prefix(8) == Data("MSWIM\0\0\0".utf8)
        else { throw WIMHeaderError.notAWIM }
        // rhXmlData at 0x48: 7-byte size, 1 flag byte (0x04 = compressed), 8-byte offset.
        let size = header[0x48..<0x4F].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        let flags = header[0x4F]
        let offset = header[0x50..<0x58].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        guard flags & 0x04 == 0, size > 0, size <= UInt64(maxXMLBytes), offset >= UInt64(headerSize) else {
            throw WIMHeaderError.unreadableImageList
        }
        try handle.seek(toOffset: offset)
        guard let xml = try handle.read(upToCount: Int(size)), xml.count == Int(size) else { throw WIMHeaderError.unreadableImageList }
        return try parse(xml)
    }

    /// `<WIM><IMAGE INDEX="n"><NAME>…</NAME><WINDOWS><ARCH>12</ARCH><VERSION><BUILD>26100</BUILD>…`
    static func parse(_ xml: Data) throws -> [WindowsImage] {
        // UTF-16LE with a BOM; XMLDocument detects the encoding from the BOM.
        guard let document = try? XMLDocument(data: xml, options: [.nodeLoadExternalEntitiesNever]) else {
            throw WIMHeaderError.unreadableImageList
        }
        let nodes = (try? document.nodes(forXPath: "/WIM/IMAGE")) ?? []
        return nodes.compactMap { node -> WindowsImage? in
            guard let image = node as? XMLElement, let index = image.attribute(forName: "INDEX")?.stringValue.flatMap(Int.init) else {
                return nil
            }
            func value(_ path: String) -> String? { (try? image.nodes(forXPath: path))?.first?.stringValue }
            return WindowsImage(
                index: index, name: value("NAME") ?? value("DISPLAYNAME") ?? "Image \(index)",
                architecture: value("WINDOWS/ARCH").flatMap(Int.init), build: value("WINDOWS/VERSION/BUILD").flatMap(Int.init))
        }
    }
}
