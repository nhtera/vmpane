import Foundation
import VMPaneControl
import VMPaneCore
import os

/// One connection to a guest agent. The host treats every byte from the guest as untrusted:
/// - nothing but `hello` is accepted first, and the agent's protocol range must overlap the host's;
/// - after that the guest may only answer requests, send the notifications in `AgentMethod.fromGuest` and send
///   data on streams the host learned about from a response;
/// - limits (frame size, JSON depth and strings, open streams, `clipboard.changed` rate) hold throughout.
///
/// Any violation closes the connection; the caller (`AgentHub`) backs off before accepting the next one.
public actor AgentConnection {
    struct Pending {
        var streams: StreamNames
        var continuation: CheckedContinuation<CallResult, Error>?
        var early: Result<CallResult, Error>?
        var expired = false
    }

    static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "agent")

    let socket: AgentSocket
    let hostVersion: String
    let token: String?
    let hostRange: ClosedRange<UInt32>
    var decoder = AgentFrameDecoder()
    var peer: Peer?
    var helloWaiter: CheckedContinuation<Peer, Error>?
    var pending: [Int64: Pending] = [:]
    var inbound: [UInt32: AgentInbound] = [:]
    var outbound: Set<UInt32> = []
    var nextID: Int64 = 1
    var nextHostStream: UInt32 = 1
    var clipboardNotices: [ContinuousClock.Instant] = []
    /// When the last bytes arrived, and whether reading is held back by a full stream (`watchIdle`).
    var lastReceived = ContinuousClock.now
    var readingPaused = false
    /// The VM is paused: its agent cannot send heartbeats, so silence then is not a dead agent (`setGuestPaused`).
    var guestPaused = false
    /// Bytes read from the agent on this connection, and up to where they were acknowledged (`transport.ack`).
    var receivedBytes: UInt64 = 0
    var acknowledgedBytes: UInt64 = 0
    /// An agent that asks for acknowledgements hears of every this many bytes read.
    static let ackEvery: UInt64 = 32 << 10

    /// `vmpane-agent-proto::limits::HEARTBEAT_SECONDS`.
    static let heartbeat: Duration = .seconds(5)
    /// The agent's heartbeat period here (tests shorten it); `watchIdle` allows three of them.
    let heartbeat: Duration
    /// Set while a refusal is being written: input is ignored, the connection closes once it is out.
    var refusing = false
    /// A QEMU port (`UDSAgentLink`), whose guest never sees a connection close: what it sends before `hello` is the
    /// session of an earlier connection, which `resetStaleSession` ends instead of closing this one.
    let portOutlivesConnections: Bool
    var lastStaleReset: ContinuousClock.Instant?
    var closeReason: ConnectionError?
    /// `exec.exited` and `clipboard.changed` from the guest. Finishes when the connection closes.
    public nonisolated let notifications: AsyncStream<RPCRequest>
    let notificationContinuation: AsyncStream<RPCRequest>.Continuation
    /// Yields once, with the reason, when the connection closes.
    public nonisolated let closed: AsyncStream<ConnectionError>
    let closedContinuation: AsyncStream<ConnectionError>.Continuation

    /// `token`: required in `hello` when set (TCP). `hostRange`: protocol versions the host speaks.
    init(
        socket: AgentSocket, hostVersion: String, token: String? = nil,
        hostRange: ClosedRange<UInt32> = AgentLimits.minProto...AgentLimits.proto, heartbeat: Duration = AgentConnection.heartbeat,
        portOutlivesConnections: Bool = false
    ) {
        self.socket = socket
        self.portOutlivesConnections = portOutlivesConnections
        self.heartbeat = heartbeat
        self.hostVersion = hostVersion
        self.token = token
        self.hostRange = hostRange
        (notifications, notificationContinuation) = AsyncStream.makeStream(of: RPCRequest.self, bufferingPolicy: .bufferingNewest(1024))
        (closed, closedContinuation) = AsyncStream.makeStream(of: ConnectionError.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Takes ownership of a connected socket descriptor.
    public init(fd: Int32, hostVersion: String, token: String? = nil, portOutlivesConnections: Bool = false) {
        self.init(socket: AgentSocket(fd: fd), hostVersion: hostVersion, token: token, portOutlivesConnections: portOutlivesConnections)
    }

    public var isOpen: Bool { closeReason == nil }
    public var agent: Peer? { peer }

    // MARK: - Opening

    /// Starts reading and returns the agent's `hello` once accepted. `helloTimeout` nil waits indefinitely
    /// (a QEMU port is connected before the guest has booted).
    public func open(helloTimeout: Duration?) async throws -> Peer {
        let (bytes, consumed) = socket.reads()
        let socket = socket
        Task { [weak self] in
            for await chunk in bytes {
                guard let self else {
                    socket.close()  // nobody owns the connection any more: stop the reader thread
                    return
                }
                await self.receive(chunk)
                consumed()
            }
            await self?.close(.closed("the guest closed the connection"))
        }
        Task { [weak self] in await self?.watchIdle() }
        if let helloTimeout {
            Task { [weak self] in
                try? await Task.sleep(for: helloTimeout)
                await self?.helloTimedOut()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let peer {
                continuation.resume(returning: peer)
            } else if let closeReason {
                continuation.resume(throwing: closeReason)
            } else {
                helloWaiter = continuation
            }
        }
    }

    /// Closes a connection that has been silent for three heartbeats after `hello` (a guest that froze, or a QEMU
    /// port whose agent died without the host noticing). Not while the host itself holds back reading, nor while
    /// the VM is paused.
    func watchIdle() async {
        while closeReason == nil {
            try? await Task.sleep(for: heartbeat)
            guard peer != nil, !readingPaused, !guestPaused else { continue }
            if ContinuousClock.now - lastReceived > heartbeat * 3 {
                close(.closed("no heartbeat from the agent"))
            }
        }
    }

    /// The VM paused (true) or continued (false). A paused guest sends nothing; closing its connection then would
    /// lose the agent for good on a QEMU port, where the guest never learns of the close and keeps the old session
    /// (its heartbeats are no `hello` to a new connection). Its silence counts again from the resume.
    public func setGuestPaused(_ paused: Bool) {
        guestPaused = paused
        if !paused { lastReceived = .now }
    }

    func helloTimedOut() {
        if peer == nil { close(.violation("no hello in time")) }
    }

    // MARK: - Requests

    /// Sends a request and waits for its response.
    public func call(
        _ method: String, _ params: JSONValue? = nil, timeout: Duration = .seconds(30),
        streams: StreamNames = .none
    ) async throws -> CallResult {
        let call = try start(method, params, streams: streams)
        return try await response(call, timeout: timeout)
    }

    /// Queues a request now (anything sent afterwards follows it on the wire).
    public func start(_ method: String, _ params: JSONValue? = nil, streams: StreamNames = .none) throws -> PendingCall {
        guard peer != nil else { throw ConnectionError.closed("hello not done") }
        if let closeReason { throw closeReason }
        let id = nextID
        nextID += 1
        let frame = try encodeMessage(.request(RPCRequest(id: .int(id), method: method, params: params)))
        pending[id] = Pending(streams: streams)
        enqueue(frame)
        return PendingCall(id: id)
    }

    /// The response to `call`; on timeout the request is abandoned (a late answer is ignored).
    public func response(_ call: PendingCall, timeout: Duration) async throws -> CallResult {
        guard var entry = pending[call.id] else { throw ConnectionError.closed("unknown request") }
        if let early = entry.early {
            pending[call.id] = nil
            return try early.get()
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(call.id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            entry.continuation = continuation
            pending[call.id] = entry
        }
    }

    /// True once the response to `call` arrived (or the connection closed): stop sending its data.
    public func isAnswered(_ call: PendingCall) -> Bool {
        closeReason != nil || pending[call.id]?.early != nil
    }

    func expire(_ id: Int64) {
        guard var entry = pending[id], let continuation = entry.continuation else { return }
        entry.continuation = nil
        entry.expired = true
        pending[id] = entry
        continuation.resume(throwing: ConnectionError.timeout)
    }

    // MARK: - Host → guest streams

    /// A new host-allocated (odd) stream id to name in a request, e.g. `file.push`.
    public func openOutbound() throws -> UInt32 {
        try checkStreamRoom()
        var id = nextHostStream
        while outbound.contains(id) { id &+= 2 }
        nextHostStream = id &+ 2 == 0 ? 1 : id &+ 2
        outbound.insert(id)
        return id
    }

    /// Sends data on a host → guest stream, in chunks within the limit. Resumes once written (flow control).
    public func send(_ data: Data, on stream: UInt32) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            guard outbound.contains(stream) else { throw ConnectionError.closed("stream \(stream) is not open") }
            if let closeReason { throw closeReason }
            let end = min(offset + AgentLimits.maxChunk, data.endIndex)
            let frame = try AgentFrame.chunk(stream: stream, data: data.subdata(in: offset..<end)).encoded()
            offset = end
            try await socket.write(frame)
        }
    }

    public func end(_ stream: UInt32, status: AgentFrame.StreamStatus = .ok) async throws {
        guard outbound.remove(stream) != nil else { return }
        if let closeReason { throw closeReason }
        try await socket.write(try AgentFrame.end(stream: stream, status: status).encoded())
    }

    // MARK: - Closing

    public func close(_ reason: ConnectionError) {
        guard closeReason == nil else { return }
        closeReason = reason
        if case .violation(let why) = reason {
            Self.log.error("dropping the agent connection: \(why, privacy: .public)")
        }
        socket.close()
        helloWaiter?.resume(throwing: reason)
        helloWaiter = nil
        for (_, entry) in pending { entry.continuation?.resume(throwing: reason) }
        pending.removeAll()
        for (_, stream) in inbound { stream.finish(.failure(.disconnected)) }
        inbound.removeAll()
        outbound.removeAll()
        notificationContinuation.finish()
        closedContinuation.yield(reason)
        closedContinuation.finish()
    }

    // MARK: - Helpers

    func checkStreamRoom() throws {
        if let closeReason { throw closeReason }
        guard inbound.count + outbound.count < AgentLimits.maxOpenStreams else {
            throw ConnectionError.rpc(RPCError(code: AgentErrorCode.busy.rawValue, message: "too many open agent streams"))
        }
    }

    func encodeMessage(_ message: RPCMessage) throws -> Data {
        do {
            return try AgentFrame.message(try AgentCodec.encode(message)).encoded()
        } catch {
            throw ConnectionError.rpc(RPCError(.invalidParams, "message exceeds the agent protocol limits"))
        }
    }

    func enqueue(_ frame: Data) {
        socket.enqueue(frame) { [weak self] error in
            guard let error else { return }
            Task { await self?.close(.closed("write failed: \(error)")) }
        }
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let (a, b) = (Array(lhs.utf8), Array(rhs.utf8))
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
