import Darwin
import Foundation
import os

/// The VM's shared folders over WebDAV, for Windows guests (their WebClient maps it as a drive): each share is a
/// top-level folder `/<name>/`, path-jailed (`PathJail`), read-only shares refuse writes. Class 1 methods plus
/// the parts of class 2 Windows Explorer needs to write: LOCK always grants (one client, the VM), UNLOCK, and
/// PROPPATCH acknowledges the Win32 times it sets. Every request must start with `prefix` (an unguessable token
/// when the transport is reachable by others).
public final class WebDAVServer: @unchecked Sendable {
    static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "webdav")

    let prefix: String
    let lock = NSLock()
    var shares: [String: PathJail]
    private var listener: Int32 = -1
    private var stopped = false

    /// `prefix`: "" or "/token" (no trailing slash).
    public init(shares: [String: PathJail], prefix: String = "") {
        self.shares = shares
        self.prefix = prefix
    }

    /// Shares added or removed while the VM runs.
    public func update(shares: [String: PathJail]) { lock.withLock { self.shares = shares } }

    /// Accepts connections on `listener` (a listening socket the server now owns) until `stop()`.
    public func start(listening listener: Int32) {
        lock.withLock { self.listener = listener }
        let thread = Thread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                var enabled: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                let connection = Thread { [self] in
                    serve(client)
                    close(client)
                }
                connection.start()
            }
        }
        thread.name = "app.vmpane.webdav"
        thread.start()
    }

    public func stop() {
        lock.withLock {
            stopped = true
            if listener >= 0 {
                shutdown(listener, SHUT_RDWR)
                close(listener)
                listener = -1
            }
        }
    }

    /// Serves one connection until the client closes it (blocking).
    public func serve(_ fd: Int32) {
        let connection = HTTPConnection(fd: fd)
        do {
            while let request = try connection.nextRequest() {
                try handle(request, on: connection)
                if !request.keepAlive { return }
            }
        } catch {
            Self.log.debug("webdav connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Requests

    struct Status: Error {
        let code: Int
        let reason: String
        static let badRequest = Status(code: 400, reason: "Bad Request")
        static let forbidden = Status(code: 403, reason: "Forbidden")
        static let notFound = Status(code: 404, reason: "Not Found")
        static let notAllowed = Status(code: 405, reason: "Method Not Allowed")
        static let conflict = Status(code: 409, reason: "Conflict")
        static let preconditionFailed = Status(code: 412, reason: "Precondition Failed")
        static let unsupportedMedia = Status(code: 415, reason: "Unsupported Media Type")
        static let badGateway = Status(code: 502, reason: "Bad Gateway")
        static let insufficientStorage = Status(code: 507, reason: "Insufficient Storage")
        static let serverError = Status(code: 500, reason: "Internal Server Error")
    }

    /// A request path: which share and where in it (nil share: the root listing the shares).
    struct Target {
        var share: String?
        var parts: [String]
        var jail: PathJail?
        var isCollectionHint: Bool
    }

    private func handle(_ request: HTTPConnection.Request, on connection: HTTPConnection) throws {
        do {
            let target = try resolve(request.target)
            switch request.method {
            case "OPTIONS":
                try connection.respond(
                    200, "OK",
                    headers: [
                        ("DAV", "1, 2"), ("MS-Author-Via", "DAV"),
                        ("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK"),
                    ])
            case "PROPFIND": try propfind(target, request, on: connection)
            case "PROPPATCH": try proppatch(target, request, on: connection)
            case "GET", "HEAD": try get(target, request, on: connection)
            case "PUT": try put(target, on: connection)
            case "DELETE": try delete(target, on: connection)
            case "MKCOL": try mkcol(target, on: connection)
            case "MOVE", "COPY": try transfer(target, request, on: connection)
            case "LOCK": try lockResource(target, request, on: connection)
            case "UNLOCK": try connection.respond(204, "No Content")
            default: throw Status.notAllowed
            }
        } catch let status as Status {
            try connection.respond(status.code, status.reason, headers: [("Content-Type", "text/plain")], body: Data(status.reason.utf8))
        } catch let failure as PathJail.Failure {
            let status = Self.status(failure)
            try connection.respond(status.code, status.reason)
        }
    }

    private static func status(_ failure: PathJail.Failure) -> Status {
        switch failure {
        case .badPath: .badRequest
        case .notFound: .notFound
        case .readOnly: .forbidden
        case .system(let code):
            switch code {
            case ENOENT, ELOOP: .notFound
            case EACCES, EPERM, EROFS: .forbidden
            case EEXIST: .notAllowed
            case ENOTEMPTY, ENOTDIR, EISDIR: .conflict
            case ENOSPC, EDQUOT: .insufficientStorage
            default: .serverError
            }
        }
    }

    func resolve(_ rawTarget: String) throws -> Target {
        var path = String(rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if let schemeEnd = path.range(of: "://"), let slash = path[schemeEnd.upperBound...].firstIndex(of: "/") {
            path = String(path[slash...])  // an absolute URL (Destination headers)
        }
        guard path.hasPrefix(prefix + "/") || path == prefix else { throw Status.notFound }
        path.removeFirst(prefix.count)
        var decoded: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let name = part.removingPercentEncoding else { throw Status.badRequest }
            decoded.append(name)
        }
        let parts = try PathJail.components(decoded.joined(separator: "/"))
        guard let share = parts.first else { return Target(share: nil, parts: [], jail: nil, isCollectionHint: true) }
        guard let jail = lock.withLock({ shares[share] }) else { throw Status.notFound }
        return Target(share: share, parts: Array(parts.dropFirst()), jail: jail, isCollectionHint: path.hasSuffix("/"))
    }

    func href(_ target: Target, _ child: String? = nil, collection: Bool) -> String {
        let names = [target.share].compactMap { $0 } + target.parts + [child].compactMap { $0 }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#[]@!$&'()*+,="))
        let path = names.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
        return prefix + "/" + path + (collection && !names.isEmpty ? "/" : "")
    }

    // MARK: GET / PUT / DELETE / MKCOL

    private func get(_ target: Target, _ request: HTTPConnection.Request, on connection: HTTPConnection) throws {
        let head = request.method == "HEAD"
        guard let jail = target.jail, !target.parts.isEmpty else {
            return try connection.respond(
                200, "OK", headers: [("Content-Type", "text/plain")], body: Data("VMPane shared folders\n".utf8), head: head)
        }
        let info = try stat(jail, target.parts)
        if info.st_mode & S_IFMT == S_IFDIR {
            return try connection.respond(200, "OK", headers: [("Content-Type", "text/plain")], body: Data(), head: head)
        }
        let fd = try jail.openFile(target.parts)
        defer { close(fd) }
        let size = Int64(info.st_size)
        var headers = [
            ("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes"),
            ("Last-Modified", Self.httpDate.string(from: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))),
        ]
        if let range = request.headers["range"], let (start, end) = Self.byteRange(range, size: size) {
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(size)"))
            if head { return try connection.respond(206, "Partial Content", headers: headers, head: true) }
            return try connection.respond(
                206, "Partial Content", headers: headers, file: .init(fd: fd, offset: start, length: end - start + 1))
        }
        if head {
            var text = "HTTP/1.1 200 OK\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            return try connection.write(Data((text + "Content-Length: \(size)\r\n\r\n").utf8))
        }
        try connection.respond(200, "OK", headers: headers, file: .init(fd: fd, offset: 0, length: size))
    }

    private func put(_ target: Target, on connection: HTTPConnection) throws {
        guard let jail = target.jail, let name = target.parts.last else { throw Status.notAllowed }
        try jail.checkWritable()
        let directory = try jail.openParent(target.parts)
        defer { close(directory) }
        let existing = PathJail.info(directory, name)
        if let existing, existing.st_mode & S_IFMT == S_IFDIR { throw Status.notAllowed }
        let temporary = ".vmpane-put-\(UUID().uuidString.prefix(8))"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw PathJail.Failure.system(errno) }
        do {
            while true {
                let chunk = try connection.readBody(max: 1 << 20)
                if chunk.isEmpty { break }
                let wrote = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                guard wrote == chunk.count else { throw PathJail.Failure.system(errno) }
            }
            close(fd)
            guard renameat(directory, temporary, directory, name) == 0 else { throw PathJail.Failure.system(errno) }
        } catch {
            close(fd)
            unlinkat(directory, temporary, 0)
            throw error
        }
        try connection.respond(existing == nil ? 201 : 204, existing == nil ? "Created" : "No Content")
    }

    private func delete(_ target: Target, on connection: HTTPConnection) throws {
        guard let jail = target.jail, let name = target.parts.last else { throw Status.forbidden }
        try jail.checkWritable()
        let directory = try jail.openParent(target.parts)
        defer { close(directory) }
        var info = Darwin.stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Status.notFound }  // a link itself can go
        try Self.remove(name, in: directory)
        try connection.respond(204, "No Content")
    }

    private func mkcol(_ target: Target, on connection: HTTPConnection) throws {
        guard let jail = target.jail, let name = target.parts.last else { throw Status.notAllowed }
        guard try connection.readWholeBody().isEmpty else { throw Status.unsupportedMedia }
        try jail.checkWritable()
        let directory: Int32
        do {
            directory = try jail.openParent(target.parts)
        } catch .notFound {
            throw Status.conflict  // RFC 4918: missing intermediate collection
        }
        defer { close(directory) }
        guard mkdirat(directory, name, 0o755) == 0 else { throw errno == EEXIST ? Status.notAllowed : PathJail.Failure.system(errno) }
        try connection.respond(201, "Created")
    }
}
