import Darwin
import Foundation
import VMPaneCore

/// Where files from a guest land on the Mac (clipboard file lists, pulls): one folder per VM, normally
/// `~/Downloads/VMPane/<vm>/` (Red Team #13). The guest names the files, so nothing it says is used as a path:
/// each name is one sanitized component; folders are walked with `openat` and `O_NOFOLLOW`, so a symlink placed
/// in the destination cannot redirect a write; files are created with `O_EXCL` (never overwritten, never
/// through a link) and get the quarantine attribute, so Gatekeeper treats them as downloads. A transfer has a
/// file-count and a byte budget.
public final class HostFileSink: @unchecked Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badName(String)
        case tooMany(Int)
        case tooLarge(Int64)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .badName(let name): "the guest named a file \(name.debugDescription), which is not a plain file name"
            case .tooMany(let limit): "more than \(limit) files"
            case .tooLarge(let limit): "more than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"
            case .system(let what, let code): "\(what): \(String(cString: strerror(code)))"
            }
        }
    }

    public static let defaultMaxFiles = 1000
    public static let defaultMaxBytes: Int64 = 2 << 30

    public let root: URL
    private let maxFiles: Int
    private let maxBytes: Int64
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0

    /// A sink for one transfer into `root` (created if missing).
    public init(root: URL, maxFiles: Int = defaultMaxFiles, maxBytes: Int64 = defaultMaxBytes) {
        self.root = root
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
    }

    /// `~/Downloads/VMPane/<vm name>/`.
    public static func downloads(forVM name: String) -> URL {
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("VMPane", isDirectory: true)
            .appendingPathComponent(sanitizedName(name) ?? "VM", isDirectory: true)
    }

    /// `name` as one safe path component (Unicode NFC), or nil: empty, `.`/`..`, separators, control characters,
    /// and names over 255 bytes are refused; surrounding spaces are trimmed.
    public static func sanitizedName(_ name: String) -> String? { SafeName.component(name) }

    /// Creates the file at `relativePath` (components separated by "/", each sanitized; folders made as needed)
    /// and returns it open for writing with where it is. An existing name gets " 2", " 3"… before its extension.
    /// Counts against the file budget; `expectedBytes` counts against the byte budget.
    public func create(_ relativePath: String, expectedBytes: Int64 = 0) throws -> (handle: FileHandle, url: URL) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { throw Failure.badName(relativePath) }
        let names = try parts.map { part -> String in
            guard let name = Self.sanitizedName(part) else { throw Failure.badName(part) }
            return name
        }
        try reserve(files: 1, bytes: expectedBytes)
        var directory = try openRoot()
        var url = root
        defer { close(directory) }
        for name in names.dropLast() {
            if mkdirat(directory, name, 0o755) != 0, errno != EEXIST { throw Failure.system("create folder \(name)", errno) }
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw Failure.system("open folder \(name)", errno) }
            close(directory)
            directory = next
            url.appendPathComponent(name, isDirectory: true)
        }
        let file = try createUnique(names[names.count - 1], in: directory)
        try Self.quarantine(file.fd)
        return (FileHandle(fileDescriptor: file.fd, closeOnDealloc: true), url.appendingPathComponent(file.name))
    }

    /// Counts `bytes` more against the budget (for transfers whose size is learnt while copying).
    public func reserve(files: Int = 0, bytes: Int64) throws {
        try lock.withLock {
            guard self.files + files <= maxFiles else { throw Failure.tooMany(maxFiles) }
            guard self.bytes + bytes <= maxBytes else { throw Failure.tooLarge(maxBytes) }
            self.files += files
            self.bytes += bytes
        }
    }

    /// The root folder, opened without following a link at any level VMPane creates.
    private func openRoot() throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.system("open \(root.path)", errno) }
        return fd
    }

    private func createUnique(_ name: String, in directory: Int32) throws -> (fd: Int32, name: String) {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? name : (ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)")
            let fd = openat(directory, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if fd >= 0 { return (fd, candidate) }
            guard errno == EEXIST else { throw Failure.system("create \(candidate)", errno) }
        }
        throw Failure.system("create \(name)", EEXIST)
    }

    /// Marks a file as downloaded (Gatekeeper checks it before it is first opened).
    static func quarantine(_ fd: Int32) throws {
        let value = String(format: "0081;%08x;VMPane;", Int(Date().timeIntervalSince1970))
        let result = value.withCString { fsetxattr(fd, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        guard result == 0 else { throw Failure.system("quarantine", errno) }
    }
}
