import Darwin
import Foundation

/// `run/<sid>.pid`: the helper that owns a VM right now.
public struct HelperRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var process: ProcessRecord
    public var runtimeVersion: String
    /// Bundle path, so a reconciler can take the bundle lock without the library.
    public var bundlePath: String
    public var vmId: UUID

    public init(process: ProcessRecord, runtimeVersion: String, bundlePath: String, vmId: UUID) {
        schemaVersion = Self.schemaVersion
        self.process = process
        self.runtimeVersion = runtimeVersion
        self.bundlePath = bundlePath
        self.vmId = vmId
    }
}

/// The run-directory files of one VM (`<sid>.pid`, `.sock`, `.children`, `<sid>/`).
public struct RunFiles: Sendable {
    public let paths: VMPanePaths
    public let sid: ShortID

    public init(paths: VMPanePaths, sid: ShortID) {
        self.paths = paths
        self.sid = sid
    }

    public var pidURL: URL { paths.pidFile(for: sid) }
    public var socketURL: URL { paths.socket(for: sid) }
    public var childrenURL: URL { paths.childrenFile(for: sid) }
    public var childDirectory: URL { paths.childDirectory(for: sid) }

    public func ensureRunDirectory() throws {
        try FileManager.default.createDirectory(
            at: paths.runDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(paths.runDirectory.path, 0o700)
    }

    /// The helper record, or nil if missing, unreadable or written by a newer VMPane. Callers must not
    /// treat nil as "no helper": an unreadable file is left alone.
    public func readHelper() -> HelperRecord? {
        guard let data = try? Data(contentsOf: pidURL),
            let record = try? CanonicalJSON.decoder().decode(HelperRecord.self, from: data),
            record.schemaVersion <= HelperRecord.schemaVersion
        else { return nil }
        return record
    }

    public var helperFileExists: Bool { FileManager.default.fileExists(atPath: pidURL.path) }

    public func writeHelper(_ record: HelperRecord) throws {
        try ensureRunDirectory()
        try DurableWrite.write(CanonicalJSON.encode(record), to: pidURL)
    }

    /// One line of the children file: a child and the helper that started it.
    public struct ChildEntry: Codable, Equatable, Sendable {
        public var process: ProcessRecord
        public var parent: ProcessRecord
    }

    public func readChildEntries() -> [ChildEntry] {
        guard let text = try? String(contentsOf: childrenURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(ChildEntry.self, from: Data($0.utf8)) }
    }

    /// Child processes recorded by the helper (QEMU, swtpm, …).
    public func readChildren() -> [ProcessRecord] { readChildEntries().map(\.process) }

    public func writeChildren(_ children: [ProcessRecord], parent: ProcessRecord) throws {
        try ensureRunDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for child in children {
            data.append(try encoder.encode(ChildEntry(process: child, parent: parent)))
            data.append(0x0A)
        }
        try DurableWrite.write(data, to: childrenURL)
    }

    /// Stops the children `parent` recorded (verified by pid + start time) and waits for each to exit.
    /// Children recorded by any other helper are never touched, so a reaper racing with a new helper
    /// cannot hit the new helper's children. Returns the children that could not be stopped.
    @discardableResult
    public func reapChildren(of parent: ProcessRecord) -> [ProcessRecord] {
        readChildEntries().filter { $0.parent.matches(parent) }.map(\.process).filter { !$0.terminate() }
    }

    /// Removes the socket, pid file, children file and child directory.
    public func removeAll() {
        let fm = FileManager.default
        for url in [socketURL, pidURL, childrenURL, childDirectory] { try? fm.removeItem(at: url) }
    }
}
