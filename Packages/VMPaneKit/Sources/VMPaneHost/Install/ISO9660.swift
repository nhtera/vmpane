import Foundation

/// Reads an ISO 9660 image's directory tree without mounting it. macOS cannot mount some hybrid arm64 ISOs (Debian's
/// netinst: "no mountable file systems", because of the partition table in its system area), but every
/// Linux installer ISO carries the ISO 9660 tree.
enum ISO9660 {
    private static let sectorSize: UInt64 = 2048
    /// Directories larger than this are not read (a damaged or hostile image).
    private static let maxDirectoryBytes: UInt32 = 4 << 20

    /// Whether the file at `path` (components, compared without case or ";1" versions) is in the image; nil when
    /// the image is not ISO 9660 or cannot be read.
    static func containsFile(_ path: [String], in image: URL) -> Bool? {
        guard !path.isEmpty, let handle = try? FileHandle(forReadingFrom: image) else { return nil }
        defer { try? handle.close() }
        guard var directory = rootDirectory(handle) else { return nil }
        for (index, name) in path.enumerated() {
            guard let records = records(handle, directory) else { return nil }
            guard let entry = records.first(where: { $0.name == normalized(name) }) else { return false }
            if index == path.count - 1 { return !entry.isDirectory }
            guard entry.isDirectory else { return false }
            directory = (entry.extent, entry.size)
        }
        return false
    }

    private struct Record {
        let name: String
        let extent: UInt32
        let size: UInt32
        let isDirectory: Bool
    }

    /// The root directory's extent and size, from the primary volume descriptor (sector 16 on; "CD001").
    private static func rootDirectory(_ handle: FileHandle) -> (UInt32, UInt32)? {
        for sector in UInt64(16)..<64 {
            guard let descriptor = read(handle, at: sector * sectorSize, count: Int(sectorSize)),
                descriptor.count == Int(sectorSize), Array(descriptor[1...5]) == Array("CD001".utf8)
            else { return nil }
            if descriptor[0] == 1 { return (le32(descriptor, 156 + 2), le32(descriptor, 156 + 10)) }  // root record at 156
            if descriptor[0] == 255 { return nil }  // terminator: no primary descriptor
        }
        return nil
    }

    private static func records(_ handle: FileHandle, _ directory: (extent: UInt32, size: UInt32)) -> [Record]? {
        guard directory.size <= maxDirectoryBytes,
            let bytes = read(handle, at: UInt64(directory.extent) * sectorSize, count: Int(directory.size))
        else { return nil }
        var records: [Record] = []
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            guard length > 0 else {  // records do not cross sectors: the rest of this one is padding
                offset = (offset / Int(sectorSize) + 1) * Int(sectorSize)
                continue
            }
            guard length >= 34, offset + length <= bytes.count else { break }
            let record = Array(bytes[offset..<offset + length])
            let nameLength = Int(record[32])
            // Names 0 and 1 are "." and ".."; primary names are ASCII.
            if 33 + nameLength <= length, nameLength > 0, record[33] > 1,
                let name = String(bytes: record[33..<33 + nameLength], encoding: .ascii)
            {
                records.append(
                    Record(
                        name: normalized(name), extent: le32(record, 2), size: le32(record, 10),
                        isDirectory: record[25] & 0x02 != 0))
            }
            offset += length
        }
        return records
    }

    /// "BOOTAA64.EFI;1" and "bootaa64.efi" are the same name.
    private static func normalized(_ name: String) -> String {
        var name = name.split(separator: ";", maxSplits: 1).first.map(String.init) ?? name
        if name.hasSuffix(".") { name.removeLast() }
        return name.uppercased()
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count) else { return nil }
        return Array(data)
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
