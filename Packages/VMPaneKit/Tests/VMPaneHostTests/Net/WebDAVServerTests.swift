import Darwin
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

/// A server on a Unix socket with a writable share "Projects" and a read-only "Reference", driven by curl.
private struct DAV {
    let root: URL
    let socket: URL
    let server: WebDAVServer

    static func start(prefix: String = "") throws -> DAV {
        let root = URL(fileURLWithPath: "/tmp/vp-dav-\(UUID().uuidString.prefix(8))")
        for name in ["Projects", "Reference", "outside"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: root.appendingPathComponent("outside/secret.txt"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("Reference/notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Projects/escape"), withDestinationURL: root.appendingPathComponent("outside"))
        let server = WebDAVServer(
            shares: [
                "Projects": PathJail(root: root.appendingPathComponent("Projects"), readOnly: false),
                "Reference": PathJail(root: root.appendingPathComponent("Reference"), readOnly: true),
            ], prefix: prefix)
        let socket = root.appendingPathComponent("dav.sock")
        let listener = try UnixSocket.make()
        try UnixSocket.bind(listener, to: UnixSocketAddress(socket))
        guard listen(listener, 8) == 0 else { throw POSIXError(.EIO) }
        server.start(listening: listener)
        return DAV(root: root, socket: socket, server: server)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// curl over the socket: the status code and the body.
    func curl(_ arguments: [String], input: Data? = nil) async -> Reply {
        let socket = socket.path
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments =
                    ["-s", "--max-time", "30", "--path-as-is", "--unix-socket", socket, "-D", "-", "-o", "-", "-w", "\n%{http_code}"]
                    + arguments  // (a request that never gets its answer fails its test instead of holding up the run)
                let output = Pipe()
                let stdin = Pipe()
                process.standardOutput = output
                process.standardInput = stdin
                try? process.run()
                if let input { stdin.fileHandleForWriting.write(input) }
                try? stdin.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(bytes: data, encoding: .utf8) ?? ""
                let status = Int(text.split(separator: "\n").last ?? "") ?? 0
                let parts = text.components(separatedBy: "\r\n\r\n")
                let headers = parts.dropLast().joined(separator: "\r\n\r\n")
                let body = String(parts.last?.split(separator: "\n").dropLast().joined(separator: "\n") ?? "")
                done.resume(returning: Reply(status: status, body: body, headers: headers))
            }
        }
    }
}

private struct Reply {
    let status: Int
    let body: String
    let headers: String
}

private let base = "http://vm"

@Test func sharesAreListedAndFilesRoundTrip() async throws {
    let dav = try DAV.start()
    defer { dav.stop() }
    let options = await dav.curl(["-X", "OPTIONS", "\(base)/"])
    #expect(options.status == 200 && options.headers.contains("DAV: 1, 2"))
    let root = await dav.curl(["-X", "PROPFIND", "-H", "Depth: 1", "\(base)/"])
    #expect(root.status == 207 && root.body.contains("<D:href>/Projects/</D:href>") && root.body.contains("/Reference/"))

    let put = await dav.curl(["-T", "-", "\(base)/Projects/caf%C3%A9%20menu.txt"], input: Data("hello".utf8))
    #expect(put.status == 201)
    #expect(try String(contentsOf: dav.root.appendingPathComponent("Projects/café menu.txt"), encoding: .utf8) == "hello")
    let get = await dav.curl(["\(base)/Projects/caf%C3%A9%20menu.txt"])
    #expect(get.status == 200 && get.body == "hello")
    let range = await dav.curl(["-H", "Range: bytes=1-3", "\(base)/Projects/caf%C3%A9%20menu.txt"])
    #expect(range.status == 206 && range.body == "ell")
    let replaced = await dav.curl(
        ["-T", "-", "-H", "Transfer-Encoding: chunked", "\(base)/Projects/caf%C3%A9%20menu.txt"], input: Data("bye".utf8))
    #expect(replaced.status == 204)
    #expect(try String(contentsOf: dav.root.appendingPathComponent("Projects/café menu.txt"), encoding: .utf8) == "bye")

    let listing = await dav.curl(["-X", "PROPFIND", "-H", "Depth: 1", "\(base)/Projects/"])
    #expect(listing.status == 207 && listing.body.contains("caf%C3%A9%20menu.txt") && listing.body.contains("<D:getcontentlength>3<"))
    #expect(!listing.body.contains("escape"), "symlinks are not listed")

    #expect(await dav.curl(["-X", "MKCOL", "\(base)/Projects/Docs"]).status == 201)
    #expect(await dav.curl(["-X", "MKCOL", "\(base)/Projects/Docs"]).status == 405)
    #expect(await dav.curl(["-X", "MKCOL", "\(base)/Projects/a/b"]).status == 409)
    let move = await dav.curl(["-X", "MOVE", "-H", "Destination: \(base)/Projects/Docs/m.txt", "\(base)/Projects/caf%C3%A9%20menu.txt"])
    #expect(move.status == 201)
    let copy = await dav.curl(["-X", "COPY", "-H", "Destination: \(base)/Projects/Docs2", "\(base)/Projects/Docs"])
    #expect(copy.status == 201)
    #expect(try String(contentsOf: dav.root.appendingPathComponent("Projects/Docs2/m.txt"), encoding: .utf8) == "bye")
    let noOverwrite = await dav.curl([
        "-X", "COPY", "-H", "Overwrite: F", "-H", "Destination: \(base)/Projects/Docs2", "\(base)/Projects/Docs",
    ])
    #expect(noOverwrite.status == 412)
    #expect(await dav.curl(["-X", "DELETE", "\(base)/Projects/Docs2"]).status == 204)
    #expect(!FileManager.default.fileExists(atPath: dav.root.appendingPathComponent("Projects/Docs2").path))
}

/// Windows locks a new name before writing it, then sets Win32 times.
@Test func windowsWritePatternWorks() async throws {
    let dav = try DAV.start()
    defer { dav.stop() }
    let body = Data(#"<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope></D:lockinfo>"#.utf8)
    let locked = await dav.curl(["-X", "LOCK", "--data-binary", "@-", "\(base)/Projects/new.docx"], input: body)
    #expect(locked.status == 201 && locked.headers.contains("Lock-Token: <opaquelocktoken:"))
    #expect(FileManager.default.fileExists(atPath: dav.root.appendingPathComponent("Projects/new.docx").path))
    #expect(await dav.curl(["-T", "-", "\(base)/Projects/new.docx"], input: Data("doc".utf8)).status == 204)
    let patch = Data(
        (#"<?xml version="1.0"?><D:propertyupdate xmlns:D="DAV:" xmlns:Z="urn:schemas-microsoft-com:"><D:set><D:prop>"#
            + "<Z:Win32LastModifiedTime>x</Z:Win32LastModifiedTime></D:prop></D:set></D:propertyupdate>").utf8)
    let patched = await dav.curl(["-X", "PROPPATCH", "--data-binary", "@-", "\(base)/Projects/new.docx"], input: patch)
    #expect(patched.status == 207 && patched.body.contains("Win32LastModifiedTime"))
    #expect(await dav.curl(["-X", "UNLOCK", "-H", "Lock-Token: <x>", "\(base)/Projects/new.docx"]).status == 204)
}

@Test func nothingEscapesAShareAndReadOnlyHolds() async throws {
    let dav = try DAV.start(prefix: "/t0k3n")
    defer { dav.stop() }
    let root = "\(base)/t0k3n"
    let anonymous = await dav.curl(["\(base)/Projects/"])
    #expect(anonymous.status == 404, "without the token: \(anonymous.status) \(anonymous.headers)")
    #expect(await dav.curl(["\(root)/Reference/notes.txt"]).body == "notes")
    for path in [
        "/Projects/../outside/secret.txt", "/Projects/%2e%2e/outside/secret.txt", "/Projects/escape/secret.txt", "/../outside/secret.txt",
    ] {
        let got = await dav.curl(["\(root)\(path)"])
        #expect(got.status >= 400 && !got.body.contains("secret"), "\(path)")
    }
    #expect(await dav.curl(["-X", "PUT", "--data-binary", "x", "\(root)/Projects/escape/new.txt"]).status >= 400)
    #expect(!FileManager.default.fileExists(atPath: dav.root.appendingPathComponent("outside/new.txt").path))
    #expect(await dav.curl(["-X", "DELETE", "\(root)/Projects/escape"]).status == 204, "deleting a link removes the link only")
    #expect(FileManager.default.fileExists(atPath: dav.root.appendingPathComponent("outside/secret.txt").path))
    #expect(await dav.curl(["-T", "-", "\(root)/Reference/new.txt"], input: Data("x".utf8)).status == 403)
    #expect(await dav.curl(["-X", "DELETE", "\(root)/Reference/notes.txt"]).status == 403)
    #expect(await dav.curl(["-X", "MOVE", "-H", "Destination: \(root)/Reference/x", "\(root)/Projects/"]).status >= 400)
}

/// A stopped server's accept loop must end: the next run's listener often reuses its descriptor number, and the
/// old loop (old token, old shares) would answer some of the new run's connections.
@Test func aStoppedServerNeverAnswersTheNextRun() async throws {
    let root = URL(fileURLWithPath: "/tmp/vp-dav-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("S"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appendingPathComponent("S/f"))
    let jail = ["S": PathJail(root: root.appendingPathComponent("S"), readOnly: true)]
    let (firstFD, _) = try WebDAVServer.loopbackListener()
    let first = WebDAVServer(shares: jail, prefix: "/old")
    first.start(listening: firstFD)
    first.stop()
    try await Task.sleep(for: .milliseconds(50))
    let (secondFD, port) = try WebDAVServer.loopbackListener()
    let second = WebDAVServer(shares: jail, prefix: "/new")
    second.start(listening: secondFD)
    defer { second.stop() }
    for _ in 0..<20 {
        let status = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "http://127.0.0.1:\(port)/new/S/f"]
                let output = Pipe()
                process.standardOutput = output
                try? process.run()
                let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                done.resume(returning: text)
            }
        }
        #expect(status == "200")
    }
}

/// Bytes straight to the server's socket; the reply until the server closes or 2 s pass.
private func raw(_ socket: URL, _ bytes: String) throws -> String {
    let fd = try UnixSocket.make()
    defer { close(fd) }
    try UnixSocket.connect(fd, to: UnixSocketAddress(socket))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = Array(bytes.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var reply = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = recv(fd, &chunk, chunk.count, 0)
        guard count > 0 else { break }
        reply += chunk[0..<count]
    }
    return String(bytes: reply, encoding: .utf8) ?? ""
}

/// Broken chunked bodies, with or without the token, end only that connection (the guest reaches this port).
@Test func malformedChunksDoNotStopTheServer() async throws {
    let dav = try DAV.start(prefix: "/t0ken")
    defer { dav.stop() }
    for size in ["\r\n", "-1\r\n", "+5\r\n", "FFFFFFFFFFFFFFFFF\r\n", "zz\r\n"] {
        for target in ["/wrong/Projects/x", "/t0ken/Projects/x"] {
            _ = try raw(dav.socket, "PUT \(target) HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n\(size)abc\r\n0\r\n\r\n")
        }
    }
    let wrong = try raw(dav.socket, "GET /wrong/Projects/ HTTP/1.1\r\nHost: x\r\n\r\nGET /t0ken/Projects/ HTTP/1.1\r\nHost: x\r\n\r\n")
    #expect(wrong.hasPrefix("HTTP/1.1 404") && wrong.components(separatedBy: "HTTP/1.1").count == 2, "nothing more after a wrong token")
    #expect(await dav.curl(["-X", "PROPFIND", "-H", "Depth: 0", "http://x/t0ken/Projects/"]).status == 207)
    #expect(HTTPConnection.chunkSize("1a;name=v") == 26 && HTTPConnection.chunkSize("") == nil && HTTPConnection.chunkSize("-1") == nil)
}

/// A folder is never copied into itself (that recursion would use up the helper's descriptors); renaming only
/// the case of a name keeps the file.
@Test func copiesIntoThemselvesAreRefusedAndCaseRenamesWork() async throws {
    let dav = try DAV.start()
    defer { dav.stop() }
    let base = "http://x"
    #expect(await dav.curl(["-X", "MKCOL", "\(base)/Projects/a"]).status == 201)
    #expect(await dav.curl(["-X", "COPY", "-H", "Destination: \(base)/Projects/a/b", "\(base)/Projects/a"]).status == 403)
    #expect(await dav.curl(["-X", "COPY", "-H", "Destination: \(base)/Projects/A/b", "\(base)/Projects/a"]).status == 403)
    #expect(await dav.curl(["-X", "COPY", "-H", "Destination: \(base)/Projects/a", "\(base)/Projects/a"]).status == 403)
    _ = await dav.curl(["-T", "-", "\(base)/Projects/a/note.txt"], input: Data("hi".utf8))
    #expect(await dav.curl(["-X", "MOVE", "-H", "Destination: \(base)/Projects/a/NOTE.txt", "\(base)/Projects/a/note.txt"]).status < 300)
    let names = try FileManager.default.contentsOfDirectory(atPath: dav.root.appendingPathComponent("Projects/a").path)
    #expect(names == ["NOTE.txt"])
}
