import Darwin
import Foundation

/// A minimal HTTP/1.1 server connection over a connected stream socket: requests in (headers, then a body read
/// on demand: Content-Length or chunked), responses out. Blocking; one thread per connection.
final class HTTPConnection {
    struct Request {
        var method: String
        /// The request target's path (not decoded) and query.
        var target: String
        /// Lowercased names.
        var headers: [String: String]

        var keepAlive: Bool { headers["connection"]?.lowercased() != "close" }
    }

    enum Failure: Error { case closed, malformed, tooLarge }

    static let maxHeaderBytes = 64 << 10

    let fd: Int32
    private var buffer = [UInt8]()
    private var bodyRemaining: Int?
    private var chunked = false
    private var chunkRemaining = 0
    private var bodyDone = true

    init(fd: Int32) {
        self.fd = fd
    }

    // MARK: - Reading

    /// The next request's head, or nil when the client closed between requests.
    func nextRequest() throws -> Request? {
        try drainBody()
        var end: Int?
        var scanned = 0  // bytes already searched: each read is searched once
        while end == nil {
            end = Self.headerEnd(buffer, from: max(0, scanned - 3))
            scanned = buffer.count
            if end == nil {
                guard buffer.count < Self.maxHeaderBytes else { throw Failure.tooLarge }
                guard try fill() else {
                    if buffer.isEmpty { return nil }
                    throw Failure.closed
                }
            }
        }
        guard let end, let head = String(bytes: buffer[0..<end], encoding: .utf8) else { throw Failure.malformed }
        buffer.removeFirst(end + 4)
        let request = try Self.parseHead(head)
        try prepareBody(request.headers)
        if request.headers["expect"]?.lowercased() == "100-continue" { try write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        return request
    }

    private static func parseHead(_ head: String) throws -> Request {
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers)
    }

    private func prepareBody(_ headers: [String: String]) throws {
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        if chunked {
            bodyRemaining = nil
            chunkRemaining = 0
            bodyDone = false
        } else {
            let field = headers["content-length"] ?? "0"
            guard (1...18).contains(field.count), field.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(field) else {
                throw Failure.malformed
            }
            bodyRemaining = length
            bodyDone = length == 0
        }
    }

    /// Up to `max` bytes of the body; empty at its end.
    func readBody(max: Int = 1 << 20) throws -> [UInt8] {
        guard !bodyDone else { return [] }
        if chunked {
            if chunkRemaining == 0 {
                guard let size = Self.chunkSize(try readLine()) else { throw Failure.malformed }
                if size == 0 {
                    while try !readLine().isEmpty {}  // trailers
                    bodyDone = true
                    return []
                }
                chunkRemaining = size
            }
            let chunk = try take(min(chunkRemaining, max))
            chunkRemaining -= chunk.count
            if chunkRemaining == 0 { _ = try readLine() }
            return chunk
        }
        guard let remaining = bodyRemaining, remaining > 0 else {
            bodyDone = true
            return []
        }
        let chunk = try take(min(remaining, max))
        bodyRemaining = remaining - chunk.count
        if bodyRemaining == 0 { bodyDone = true }
        return chunk
    }

    /// A chunk-size line's size: 1–15 hex digits (extensions after `;` ignored); nil for anything else.
    static func chunkSize(_ line: String) -> Int? {
        let field = (line.split(separator: ";", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
        guard (1...15).contains(field.count), field.allSatisfy(\.isHexDigit) else { return nil }
        return Int(field, radix: 16)
    }

    /// The whole body, refused past `limit` bytes.
    func readWholeBody(limit: Int = 1 << 20) throws -> Data {
        var data = Data()
        while true {
            let chunk = try readBody()
            if chunk.isEmpty { return data }
            data.append(contentsOf: chunk)
            guard data.count <= limit else { throw Failure.tooLarge }
        }
    }

    /// Skips what is left of the current body (keep-alive needs the stream positioned at the next request).
    private func drainBody() throws {
        while try !readBody().isEmpty {}
    }

    private func take(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        if buffer.isEmpty { guard try fill() else { throw Failure.closed } }
        let chunk = Array(buffer.prefix(count))
        buffer.removeFirst(chunk.count)
        return chunk
    }

    private func readLine() throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line =
                    String(bytes: buffer[0..<newline], encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) ?? ""
                buffer.removeFirst(newline + 1)
                return line
            }
            guard buffer.count < Self.maxHeaderBytes else { throw Failure.tooLarge }
            guard try fill() else { throw Failure.closed }
        }
    }

    private func fill() throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            buffer.append(contentsOf: chunk[0..<count])
            return true
        }
    }

    private static func headerEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= 4, start <= bytes.count - 4 else { return nil }
        for index in start...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    // MARK: - Writing

    func respond(_ status: Int, _ reason: String, headers: [(String, String)] = [], body: Data = Data(), head: Bool = false) throws {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.count)\r\n\r\n"
        try write(Data(text.utf8) + (head ? Data() : body))
    }

    /// Part of an open file, as a response body.
    struct FileBody {
        let fd: Int32
        let offset: Int64
        let length: Int64
    }

    /// A response whose body is part of a file.
    func respond(_ status: Int, _ reason: String, headers: [(String, String)], file body: FileBody) throws {
        let (file, offset, length) = (body.fd, body.offset, body.length)
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(length)\r\n\r\n"
        try write(Data(text.utf8))
        var sent: Int64 = 0
        var chunk = [UInt8](repeating: 0, count: 256 << 10)
        while sent < length {
            let count = pread(file, &chunk, Int(min(Int64(chunk.count), length - sent)), offset + sent)
            guard count > 0 else { throw Failure.closed }
            try write(Data(chunk[0..<count]))
            sent += Int64(count)
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = send(fd, raw.baseAddress.map { $0 + sent }, raw.count - sent, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.closed }
                sent += count
            }
        }
    }
}
