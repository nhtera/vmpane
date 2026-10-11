import CryptoKit
import Darwin
import Foundation

/// One audit line.
public struct AuditEntry: Codable, Equatable, Sendable {
    /// ISO 8601 with milliseconds, UTC (`ts` in the file).
    public var timestamp: String
    /// The agent session (one `vmpane mcp` process), if any.
    public var session: String?
    /// What the client says it is ("claude-code (claimed)").
    public var client: String?
    /// ui, operator, cli, mcp: from the client's code signature and context, not its claim.
    public var identity: String
    public var kind: String
    public var tool: String?
    public var method: String
    public var args: JSONValue?
    /// The VM's policy level at the time.
    public var policy: String
    /// ok, denied, error.
    public var result: String
    public var reason: String?
    public var exitCode: Int?
    public var durationMs: Int?

    public init(
        date: Date = Date(), session: String? = nil, client: String? = nil, identity: String, kind: String, tool: String? = nil,
        method: String, args: JSONValue? = nil, policy: String, result: String, reason: String? = nil, exitCode: Int? = nil,
        durationMs: Int? = nil
    ) {
        timestamp = Self.timestamp(date)
        self.session = session
        self.client = client
        self.identity = identity
        self.kind = kind
        self.tool = tool
        self.method = method
        self.args = args
        self.policy = policy
        self.result = result
        self.reason = reason
        self.exitCode = exitCode
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case session, client, identity, kind, tool, method, args, policy, result, reason, exitCode, durationMs
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// What VMPane's interfaces were asked to do on a VM, one JSON line per call (helper requests, Core-direct library
/// operations, denials), written and synced before the answer goes out (Red Team #1). Rotated at 10 MB, five
/// files kept. Append-only from VMPane; the user can delete it — it is a record, not tamper-proof.
public final class AuditLog: @unchecked Sendable {
    public static let maxBytes = 10 << 20
    public static let keptFiles = 5

    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int = AuditLog.maxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// A VM's log (`<bundle>/logs/mcp-audit.jsonl`).
    public convenience init(bundle: VMBundle) {
        self.init(url: bundle.url.appendingPathComponent("logs/mcp-audit.jsonl"))
    }

    /// Appends `entry` and syncs it to disk.
    public func append(_ entry: AuditEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size + line.count > maxBytes {
                rotate()
            }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == line.count, fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    /// mcp-audit.jsonl → .1 → … → .5 (the oldest dropped).
    private func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(url.path).\(Self.keptFiles)")
        for index in stride(from: Self.keptFiles - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(url.path).\(index)", toPath: "\(url.path).\(index + 1)")
        }
        try? fm.moveItem(atPath: url.path, toPath: "\(url.path).1")
    }

    /// A request's params as they are recorded: typed text and clipboard contents as SHA-256 unless the VM records
    /// typed text, exec environments by name only, file contents never (they travel on streams anyway).
    public static func recorded(method: String, params: JSONValue?, typedText: Bool) -> JSONValue? {
        guard case .object(var fields)? = params else { return params }
        func hashed(_ value: JSONValue?) -> JSONValue? {
            value?.stringValue.map { .string("sha256:" + SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()) }
        }
        switch method {
        case "vm.input.text" where !typedText:
            fields["text"] = hashed(fields["text"])
        case "vm.clipboard.write":
            if case .array(let items)? = fields["items"] {
                fields["items"] = .array(
                    items.map { item in
                        guard case .object(var entry) = item else { return item }
                        entry["text"] = hashed(entry["text"])
                        entry["dataB64"] = hashed(entry["dataB64"])
                        return .object(entry.compactMapValues { $0 })
                    })
            }
        case "agent.exec":
            if case .object(let env)? = fields["env"] { fields["env"] = .array(env.keys.sorted().map { .string($0) }) }
        case "agent.exec.input":
            fields["dataB64"] = nil
        default:
            break
        }
        return .object(fields.compactMapValues { $0 })
    }
}
