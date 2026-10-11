import Darwin
import Foundation

/// WebDAV properties, MOVE/COPY and the LOCK grants.
extension WebDAVServer {
    // MARK: PROPFIND / PROPPATCH

    func propfind(_ target: Target, _ request: HTTPConnection.Request, on connection: HTTPConnection) throws {
        _ = try connection.readWholeBody()  // which properties: all of ours are cheap, so all are sent
        let depth = request.headers["depth"] ?? "infinity"
        var responses: [String] = []
        guard let jail = target.jail else {
            responses.append(Self.response(href(target, collection: true), name: "", info: nil))
            if depth != "0" {
                let names = lock.withLock { shares.keys.sorted() }
                for name in names { responses.append(Self.response(prefix + "/" + name + "/", name: name, info: nil)) }
            }
            return try multistatus(responses, on: connection)
        }
        let info = try stat(jail, target.parts)
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        responses.append(Self.response(href(target, collection: isDirectory), name: target.parts.last ?? target.share ?? "", info: info))
        if isDirectory && depth != "0" {
            let directory = try jail.openDirectory(target.parts)
            defer { close(directory) }
            for name in try Self.entries(directory) {
                guard let child = PathJail.info(directory, name) else { continue }  // symlinks are not shown
                let childIsDirectory = child.st_mode & S_IFMT == S_IFDIR
                responses.append(Self.response(href(target, name, collection: childIsDirectory), name: name, info: child))
            }
        }
        try multistatus(responses, on: connection)
    }

    func proppatch(_ target: Target, _ request: HTTPConnection.Request, on connection: HTTPConnection) throws {
        let body = try connection.readWholeBody()
        if let jail = target.jail { _ = try stat(jail, target.parts) }
        // Windows sets Win32CreationTime/LastModifiedTime/FileAttributes after a copy: acknowledged, not stored.
        var names: [String] = []
        if let root = try? PlainXML.parse(body) {
            for update in root.children where update.name.hasSuffix("set") || update.name.hasSuffix("remove") {
                for prop in update.children where prop.name.hasSuffix("prop") { names += prop.children.map(\.name) }
            }
        }
        let props = names.map { name -> String in
            let local = name.split(separator: ":").last.map(String.init) ?? name
            return "<\(local) xmlns=\"urn:schemas-microsoft-com:\"/>"
        }.joined()
        let response = """
            <D:response><D:href>\(Self.escape(href(target, collection: target.isCollectionHint)))</D:href>\
            <D:propstat><D:prop>\(props)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            """
        try multistatus([response], on: connection)
    }

    func multistatus(_ responses: [String], on connection: HTTPConnection) throws {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">" + responses.joined() + "</D:multistatus>"
        try connection.respond(207, "Multi-Status", headers: [("Content-Type", "application/xml; charset=utf-8")], body: Data(xml.utf8))
    }

    static func response(_ href: String, name: String, info: stat?) -> String {
        var props = "<D:displayname>\(escape(name))</D:displayname>"
        let isDirectory = info.map { $0.st_mode & S_IFMT == S_IFDIR } ?? true
        props += isDirectory ? "<D:resourcetype><D:collection/></D:resourcetype>" : "<D:resourcetype/>"
        if let info {
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            let created = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
            props += "<D:getlastmodified>\(httpDate.string(from: modified))</D:getlastmodified>"
            props += "<D:creationdate>\(isoDate.string(from: created))</D:creationdate>"
            props += "<D:getetag>\"\(String(info.st_ino, radix: 16))-\(info.st_mtimespec.tv_sec)-\(info.st_size)\"</D:getetag>"
            if !isDirectory {
                props += "<D:getcontentlength>\(info.st_size)</D:getcontentlength>"
                props += "<D:getcontenttype>application/octet-stream</D:getcontenttype>"
            }
        }
        props += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype>"
        props += "</D:lockentry></D:supportedlock>"
        return "<D:response><D:href>\(escape(href))</D:href><D:propstat><D:prop>\(props)</D:prop>"
            + "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    // MARK: MOVE / COPY

    func transfer(_ target: Target, _ request: HTTPConnection.Request, on connection: HTTPConnection) throws {
        guard let jail = target.jail, let name = target.parts.last else { throw Status.forbidden }
        guard let destinationHeader = request.headers["destination"] else { throw Status.badRequest }
        let destination = try resolve(destinationHeader)
        guard destination.share == target.share, let newName = destination.parts.last else { throw Status.badGateway }
        try jail.checkWritable()
        let overwrite = request.headers["overwrite"]?.uppercased() != "F"
        let from = try jail.openParent(target.parts)
        defer { close(from) }
        guard PathJail.info(from, name) != nil else { throw Status.notFound }
        let to: Int32
        do {
            to = try jail.openParent(destination.parts)
        } catch .notFound {
            throw Status.conflict
        }
        defer { close(to) }
        let existed = PathJail.info(to, newName) != nil
        if existed {
            guard overwrite else { throw Status.preconditionFailed }
            try Self.remove(newName, in: to)
        }
        if request.method == "MOVE" {
            guard renameat(from, name, to, newName) == 0 else { throw PathJail.Failure.system(errno) }
        } else {
            try Self.copy(name, in: from, to: newName, in: to)
        }
        try connection.respond(existed ? 204 : 201, existed ? "No Content" : "Created")
    }

    // MARK: LOCK

    /// Grants every lock (the VM is the only client): Windows locks before it writes. A lock on a missing name
    /// creates the empty file, as RFC 4918 lock-null resources do now.
    func lockResource(_ target: Target, _ request: HTTPConnection.Request, on connection: HTTPConnection) throws {
        _ = try connection.readWholeBody()
        var created = false
        if let jail = target.jail, let name = target.parts.last {
            let directory = try jail.openParent(target.parts)
            defer { close(directory) }
            if PathJail.info(directory, name) == nil {
                try jail.checkWritable()
                let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw PathJail.Failure.system(errno) }
                close(fd)
                created = true
            }
        }
        let token = "opaquelocktoken:\(UUID().uuidString.lowercased())"
        let owner = "<D:owner>VMPane</D:owner>"
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype>\
            <D:lockscope><D:exclusive/></D:lockscope><D:depth>\(request.headers["depth"] ?? "infinity")</D:depth>\(owner)\
            <D:timeout>Second-3600</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken>\
            <D:lockroot><D:href>\(Self.escape(href(target, collection: target.isCollectionHint)))</D:href></D:lockroot>\
            </D:activelock></D:lockdiscovery></D:prop>
            """
        try connection.respond(
            created ? 201 : 200, created ? "Created" : "OK",
            headers: [("Lock-Token", "<\(token)>"), ("Content-Type", "application/xml; charset=utf-8")], body: Data(xml.utf8))
    }
}
