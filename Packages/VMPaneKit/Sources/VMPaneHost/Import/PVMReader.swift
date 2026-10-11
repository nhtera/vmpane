import Foundation
import VMPaneCore

/// A small XML tree (element names, attributes, text, children), read without resolving external entities.
struct PlainXML: Sendable {
    let name: String
    var attributes: [String: String] = [:]
    var text = ""
    var children: [PlainXML] = []

    /// The first direct child named `name`.
    func child(_ name: String) -> PlainXML? { children.first { $0.name == name } }

    func children(_ name: String) -> [PlainXML] { children.filter { $0.name == name } }

    /// The first element named `name` anywhere below (depth-first).
    func first(_ name: String) -> PlainXML? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parse(_ data: Data) throws -> PlainXML {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw PVMImportError.unreadable(parser.parserError.map { String(describing: $0) } ?? "not XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [PlainXML] = []
        var root: PlainXML?

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            guard stack.count < 64 else { return parser.abortParsing() }
            stack.append(PlainXML(name: name, attributes: attributes))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty, stack[stack.count - 1].text.utf8.count < 1 << 20 else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let done = stack.popLast() else { return }
            if stack.isEmpty { root = done } else { stack[stack.count - 1].children.append(done) }
        }
    }
}

public enum PVMImportError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case noDisk
    case macOSGuest
    case snapshots
    case splitDisk
    case missingImage(String)

    public var description: String {
        switch self {
        case .unreadable(let reason): "The Parallels VM's settings cannot be read (\(reason))."
        case .noDisk: "The Parallels VM has no hard disk image to import."
        case .macOSGuest: "macOS virtual machines cannot be imported from Parallels: install macOS in VMPane instead."
        case .snapshots: "The disk has Parallels snapshots. Delete them in Parallels first, then import again."
        case .splitDisk: "The disk is split into several files. Convert it to a single file in Parallels first."
        case .missingImage(let name): "The disk image \(name) is missing from the Parallels VM."
        }
    }
}

/// What VMPane takes from a Parallels VM (`config.pvs` in the `.pvm` bundle). Only the hard disk's location is
/// relied on; the name, guest OS, CPUs and memory are suggestions the import sheet shows for confirmation.
public struct ParallelsVM: Sendable, Equatable {
    public var name: String
    /// Guessed from Parallels' OS type; nil when unknown.
    public var os: GuestOS?
    public var cpuCount: Int?
    public var memoryMiB: Int?
    /// The `.hdd` folders of the enabled image-file disks, the boot disk first.
    public var disks: [URL]

    /// Reads `<pvm>/config.pvs`. The `.pvm` is only read, never changed.
    public static func read(_ pvm: URL) throws -> ParallelsVM {
        let root = try PlainXML.parse(try Data(contentsOf: pvm.appendingPathComponent("config.pvs")))
        let hardware = root.first("Hardware") ?? root
        // Image-file disks: the SystemName (a bare name is inside the .pvm) is a folder with a DiskDescriptor.xml.
        // Physical and Boot Camp disks name devices instead, and are left out.
        let disks = hardware.children("Hdd")
            .filter { $0.child("Enabled")?.value != "0" }
            .sorted { Int($0.child("Index")?.value ?? "") ?? 0 < Int($1.child("Index")?.value ?? "") ?? 0 }
            .compactMap { disk -> URL? in
                guard let name = disk.child("SystemName")?.value, !name.isEmpty else { return nil }
                let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : pvm.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.appendingPathComponent("DiskDescriptor.xml").path) ? url : nil
            }
        guard !disks.isEmpty else { throw PVMImportError.noDisk }
        let os: GuestOS? =
            switch root.first("OsType")?.value {
            case "7": .macos
            case "8": .windows
            case "9": .linux
            default: nil
            }
        if os == .macos { throw PVMImportError.macOSGuest }
        return ParallelsVM(
            name: root.first("VmName")?.value.nilIfEmpty ?? pvm.deletingPathExtension().lastPathComponent,
            os: os,
            cpuCount: hardware.first("Cpu")?.child("Number").flatMap { Int($0.value) },
            memoryMiB: hardware.first("Memory")?.child("RAM").flatMap { Int($0.value) },
            disks: disks)
    }
}

/// A Parallels disk (`harddisk.hdd/DiskDescriptor.xml`): the image file holding its current contents.
public struct ParallelsDisk: Sendable, Equatable {
    public enum Format: String, Sendable { case plain = "Plain", expanding = "Compressed" }

    public var image: URL
    public var format: Format
    /// The virtual size.
    public var sizeBytes: UInt64

    /// The predefined GUID of a disk's only state (QEMU's prl-xml notes).
    static let baseGUID = "{5fbaabe3-6958-40ff-92a7-860e329aab41}"

    /// Reads the descriptor. Disks with snapshots or split into several files are refused.
    public static func read(_ hdd: URL) throws -> ParallelsDisk {
        let root = try PlainXML.parse(try Data(contentsOf: hdd.appendingPathComponent("DiskDescriptor.xml")))
        if (root.child("Snapshots")?.children("Shot").count ?? 0) > 1 { throw PVMImportError.snapshots }
        let storages = root.child("StorageData")?.children("Storage") ?? []
        guard storages.count == 1, let storage = storages.first else { throw PVMImportError.splitDisk }
        let top = root.child("Snapshots")?.child("TopGUID")?.value.nilIfEmpty ?? baseGUID
        let images = storage.children("Image")
        guard let image = images.first(where: { $0.child("GUID")?.value.lowercased() == top.lowercased() }) ?? images.first,
            let file = image.child("File")?.value, !file.isEmpty
        else { throw PVMImportError.noDisk }
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : hdd.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PVMImportError.missingImage(url.lastPathComponent) }
        let sectors = root.child("Disk_Parameters")?.child("Disk_size").flatMap { UInt64($0.value) } ?? 0
        return ParallelsDisk(
            image: url, format: Format(rawValue: image.child("Type")?.value ?? "") ?? .expanding, sizeBytes: sectors * 512)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
