import Foundation

/// Agent-protocol method names, caps, error codes and parameter/result types. Mirror of
/// `vmpane-agent-proto::methods` (the Rust types are the schema source; `agent/proto/schema/protocol.json`
/// is checked against these names by the conformance tests). Every type decodes leniently: unknown fields are
/// ignored and optional fields may be absent.
public enum AgentMethod {
    public static let hello = "hello"
    public static let agentInfo = "agent.info"
    public static let agentPing = "agent.ping"
    /// Guest → host every few seconds (`vmpane-agent-proto::limits::HEARTBEAT_SECONDS`); ignored by the host.
    public static let agentHeartbeat = "agent.heartbeat"
    /// Host → guest `{bytes}`: how many bytes the host has read on this connection; to agents with `AgentCap.ack`.
    public static let transportAck = "transport.ack"
    public static let execStart = "exec.start"
    public static let execSignal = "exec.signal"
    public static let execExited = "exec.exited"
    public static let filePush = "file.push"
    public static let filePull = "file.pull"
    public static let fileStat = "file.stat"
    public static let fileMkdirTemp = "file.mkdirTemp"
    public static let sessionReveal = "session.reveal"
    public static let clipboardGet = "clipboard.get"
    public static let clipboardSet = "clipboard.set"
    public static let clipboardChanged = "clipboard.changed"
    public static let displaySet = "display.set"
    public static let timeSet = "time.set"
    public static let powerShutdown = "power.shutdown"
    public static let netAddrs = "net.addrs"
    public static let portsListening = "ports.listening"
    public static let fsFreeze = "fs.freeze"
    public static let fsThaw = "fs.thaw"

    /// Methods the guest may send. Anything else from the guest is a protocol violation.
    public static let fromGuest: Set<String> = [hello, agentHeartbeat, execExited, clipboardChanged]
}

public enum AgentCap {
    public static let exec = "exec"
    public static let file = "file"
    public static let clipboard = "clipboard"
    public static let clipboardFiles = "clipboard.files"
    public static let time = "time"
    public static let power = "power"
    public static let net = "net"
    public static let ports = "ports"
    public static let display = "display"
    public static let freeze = "freeze"
    public static let reveal = "reveal"
    /// The agent wants `transport.ack` (macOS guests: their vsock stalls with about 240 KiB in flight).
    public static let ack = "ack"
}

/// The agent protocol's own error codes (JSON-RPC's standard ones are in `ControlErrorCode`).
public enum AgentErrorCode: Int, Sendable, CaseIterable {
    case protoUnsupported = -32017
    case helloRequired = -32040
    case capUnsupported = -32041
    case notFound = -32042
    case permissionDenied = -32043
    case ioError = -32044
    case timeout = -32045
    case tooLarge = -32046
    case busy = -32047
    case noSession = -32048
    case integrity = -32049
    case unauthorized = -32050
}

public struct AgentEmpty: Codable, Equatable, Sendable {
    public init() {}
}

public struct AgentHelloParams: Codable, Equatable, Sendable {
    public var proto: UInt32
    public var minProto: UInt32
    public var agentVersion: String
    public var os: String
    public var arch: String
    public var osVersion: String?
    public var caps: [String]?
    public var session: Bool?
    public var token: String?

    public init(
        proto: UInt32, minProto: UInt32, agentVersion: String, os: String, arch: String, osVersion: String? = nil,
        caps: [String]? = nil, session: Bool? = nil, token: String? = nil
    ) {
        self.proto = proto
        self.minProto = minProto
        self.agentVersion = agentVersion
        self.os = os
        self.arch = arch
        self.osVersion = osVersion
        self.caps = caps
        self.session = session
        self.token = token
    }
}

public struct AgentHelloResult: Codable, Equatable, Sendable {
    public var proto: UInt32
    public var hostVersion: String

    public init(proto: UInt32, hostVersion: String) {
        self.proto = proto
        self.hostVersion = hostVersion
    }
}

public struct AgentInfo: Codable, Equatable, Sendable {
    public var agentVersion: String
    public var proto: UInt32
    public var os: String
    public var arch: String
    public var osVersion: String?
    public var caps: [String]?
    public var session: Bool?
    public var uptimeMs: UInt64?
}

public enum AgentRunAs: String, Codable, Sendable {
    case user, admin
}

public struct AgentExecStartParams: Codable, Equatable, Sendable {
    public var argv: [String]?
    public var shell: String?
    public var env: [String: String]?
    public var cwd: String?
    public var runAs: AgentRunAs
    public var stdin: Bool
    public var timeoutMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case argv, shell, env, cwd, stdin, timeoutMs
        case runAs = "as"
    }

    public init(
        argv: [String]? = nil, shell: String? = nil, env: [String: String]? = nil, cwd: String? = nil,
        as runAs: AgentRunAs = .user, stdin: Bool = false, timeoutMs: UInt64? = nil
    ) {
        self.argv = argv
        self.shell = shell
        self.env = env
        self.cwd = cwd
        self.runAs = runAs
        self.stdin = stdin
        self.timeoutMs = timeoutMs
    }
}

public struct AgentExecStartResult: Codable, Equatable, Sendable {
    public var execId: UInt32
    public var stdout: UInt32
    public var stderr: UInt32
    public var stdin: UInt32?
}

public enum AgentSignal: String, Codable, Sendable {
    case int, term, kill
}

public struct AgentExecSignalParams: Codable, Equatable, Sendable {
    public var execId: UInt32
    public var signal: AgentSignal

    public init(execId: UInt32, signal: AgentSignal) {
        self.execId = execId
        self.signal = signal
    }
}

public struct AgentExecExited: Codable, Equatable, Sendable {
    public var execId: UInt32
    public var code: Int32?
    public var signal: String?
    public var timedOut: Bool?
}

public struct AgentFilePushParams: Codable, Equatable, Sendable {
    public var path: String
    public var mode: UInt32?
    public var size: UInt64
    public var sha256: String
    public var stream: UInt32
    public var overwrite: Bool

    public init(path: String, mode: UInt32? = nil, size: UInt64, sha256: String, stream: UInt32, overwrite: Bool = false) {
        self.path = path
        self.mode = mode
        self.size = size
        self.sha256 = sha256
        self.stream = stream
        self.overwrite = overwrite
    }
}

public struct AgentFilePushResult: Codable, Equatable, Sendable {
    public var size: UInt64
    public var sha256: String
}

public struct AgentFilePullParams: Codable, Equatable, Sendable {
    public var path: String
    public var maxBytes: UInt64

    public init(path: String, maxBytes: UInt64) {
        self.path = path
        self.maxBytes = maxBytes
    }
}

public struct AgentFilePullResult: Codable, Equatable, Sendable {
    public var size: UInt64
    public var stream: UInt32
}

public struct AgentPathParams: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) { self.path = path }
}

public struct AgentFileStat: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, dir, symlink, other }
    public var kind: Kind
    public var size: UInt64
    public var mode: UInt32?
    public var mtimeUnixNanos: Int64?
}

public enum AgentClipboardType: String, Codable, Sendable {
    case text, png, files
}

public struct AgentClipboardItem: Codable, Equatable, Sendable {
    public var type: AgentClipboardType
    public var stream: UInt32?
    public var size: UInt64?
    public var files: [String]?

    public init(type: AgentClipboardType, stream: UInt32? = nil, size: UInt64? = nil, files: [String]? = nil) {
        self.type = type
        self.stream = stream
        self.size = size
        self.files = files
    }
}

public struct AgentClipboardGetParams: Codable, Equatable, Sendable {
    public var types: [AgentClipboardType]

    public init(types: [AgentClipboardType]) { self.types = types }
}

public struct AgentClipboardContents: Codable, Equatable, Sendable {
    public var items: [AgentClipboardItem]

    public init(items: [AgentClipboardItem]) { self.items = items }
}

public struct AgentClipboardChanged: Codable, Equatable, Sendable {
    public var types: [AgentClipboardType]
    public var seq: UInt64
}

public struct AgentDisplaySetParams: Codable, Equatable, Sendable {
    public var widthPx: UInt32
    public var heightPx: UInt32
    public var scale: Double

    public init(widthPx: UInt32, heightPx: UInt32, scale: Double = 1) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.scale = scale
    }
}

public struct AgentTimeSetParams: Codable, Equatable, Sendable {
    public var unixNanos: Int64

    public init(unixNanos: Int64) { self.unixNanos = unixNanos }
}

public struct AgentPowerShutdownParams: Codable, Equatable, Sendable {
    public var reboot: Bool
    public var force: Bool

    public init(reboot: Bool = false, force: Bool = false) {
        self.reboot = reboot
        self.force = force
    }
}

public struct AgentNetAddrs: Codable, Equatable, Sendable {
    public struct Interface: Codable, Equatable, Sendable {
        public var name: String
        public var mac: String?
        public var ipv4: [String]?
        public var ipv6: [String]?
    }
    public var interfaces: [Interface]
}

public enum AgentPortProto: String, Codable, Sendable { case tcp, udp }

public struct AgentPortsListening: Codable, Equatable, Sendable {
    public struct Port: Codable, Equatable, Sendable {
        public var proto: AgentPortProto
        public var address: String
        public var port: UInt16
        public var process: String?
    }
    public var ports: [Port]
}

public struct AgentFsFreezeParams: Codable, Equatable, Sendable {
    public var timeoutMs: UInt64?

    public init(timeoutMs: UInt64? = nil) { self.timeoutMs = timeoutMs }
}

public struct AgentFsFreezeResult: Codable, Equatable, Sendable {
    public var frozen: [String]
}

public struct AgentFsThawResult: Codable, Equatable, Sendable {
    public var thawed: [String]
}
