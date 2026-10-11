import Darwin
import Foundation

/// The WebDAV server's file-system work (never through a link) and its formatting.
extension WebDAVServer {
    // MARK: - File system

    func stat(_ jail: PathJail, _ parts: [String]) throws -> Darwin.stat {
        guard let name = parts.last else {
            var info = Darwin.stat()
            guard fstatat(AT_FDCWD, jail.root.path, &info, 0) == 0 else { throw PathJail.Failure.system(errno) }
            return info
        }
        let directory = try jail.openParent(parts)
        defer { close(directory) }
        guard let info = PathJail.info(directory, name) else { throw Status.notFound }
        return info
    }

    static func entries(_ directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else { throw PathJail.Failure.system(errno) }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != "..", !name.hasPrefix(".vmpane-put-") { names.append(name) }
        }
        return names.sorted()
    }

    /// How deep a recursive copy or removal goes: each level holds descriptors, and the helper needs its own.
    static let maxDepth = 64

    /// Removes `name` (a file, a link itself, or a folder and everything in it) without following links.
    static func remove(_ name: String, in directory: Int32, depth: Int = 0) throws {
        guard depth < maxDepth else { throw PathJail.Failure.system(ENAMETOOLONG) }
        var info = Darwin.stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw PathJail.Failure.system(errno) }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw PathJail.Failure.system(errno) }
            defer { close(child) }
            for entry in try entries(child) { try remove(entry, in: child, depth: depth + 1) }
            guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw PathJail.Failure.system(errno) }
        } else {
            guard unlinkat(directory, name, 0) == 0 else { throw PathJail.Failure.system(errno) }
        }
    }

    /// Copies `name` (file or folder; links are skipped) into `target` as `newName`.
    static func copy(_ name: String, in source: Int32, to newName: String, in target: Int32, depth: Int = 0) throws {
        guard depth < maxDepth else { throw PathJail.Failure.system(ENAMETOOLONG) }
        guard let info = PathJail.info(source, name) else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard mkdirat(target, newName, 0o755) == 0 else { throw PathJail.Failure.system(errno) }
            let from = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let to = openat(target, newName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            defer {
                close(from)
                close(to)
            }
            guard from >= 0, to >= 0 else { throw PathJail.Failure.system(errno) }
            for entry in try entries(from) { try copy(entry, in: from, to: entry, in: to, depth: depth + 1) }
            return
        }
        let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw PathJail.Failure.system(errno) }
        defer { close(input) }
        let output = openat(target, newName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw PathJail.Failure.system(errno) }
        defer { close(output) }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw PathJail.Failure.system(errno) }
    }

    // MARK: - Formatting

    static func byteRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        guard header.hasPrefix("bytes="), !header.contains(","), size > 0 else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty, let suffix = Int64(bounds[1]), suffix > 0 { return (max(size - suffix, 0), size - 1) }
        guard let start = Int64(bounds[0]), start < size else { return nil }
        let end = bounds[1].isEmpty ? size - 1 : min(Int64(bounds[1]) ?? size - 1, size - 1)
        return start <= end ? (start, end) : nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// Only formats (thread-safe for that).
    nonisolated(unsafe) static let isoDate = ISO8601DateFormatter()

    /// A listening socket on 127.0.0.1 at a port the system picks, and that port.
    public static func loopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = try Sockets.bound("127.0.0.1", 0, stream: true)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            close(fd)
            throw SocketError(call: "getsockname", code: code)
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}
