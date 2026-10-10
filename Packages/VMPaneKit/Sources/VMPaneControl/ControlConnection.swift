import Darwin
import Foundation
import VMPaneCore

/// One accepted control connection. Reads and writes happen on its own serial queue, so a slow client
/// only stalls itself.
public final class ControlConnection: @unchecked Sendable, Hashable {
    public let peer: PeerCredentials
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer()
    private var closed = false
    /// The peer finished sending (half-close, e.g. `echo … | nc -U`): close once in-flight requests are answered.
    private var peerFinished = false
    private var inFlight = 0
    private var subscribedTopics: Set<String> = []
    private let onLine: @Sendable (ControlConnection, Data) -> Void
    private let onClose: @Sendable (ControlConnection) -> Void

    init(
        fd: Int32, peer: PeerCredentials, onLine: @escaping @Sendable (ControlConnection, Data) -> Void,
        onClose: @escaping @Sendable (ControlConnection) -> Void
    ) {
        self.fd = fd
        self.peer = peer
        self.onLine = onLine
        self.onClose = onClose
        queue = DispatchQueue(label: "app.vmpane.control.connection.\(fd)")
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &buffer, buffer.count)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        if count < 0 {
            closeOnQueue()
            return
        }
        if count == 0 {
            // End of input. Answer what is still running before closing.
            peerFinished = true
            readSource?.suspend()
            if inFlight == 0 { closeOnQueue() }
            return
        }
        for event in framer.append(Data(buffer[0..<count])) {
            switch event {
            case .line(let line):
                onLine(self, line)
            case .overflow:
                writeOnQueue(.response(RPCResponse(id: nil, error: RPCError(.invalidRequest, "request line exceeds 1 MiB"))))
                closeOnQueue()
                return
            }
        }
    }

    /// Marks a request as running; `finishRequest` must follow (after its response, if any, is sent).
    /// Called from the line handler, which runs on this connection's queue.
    func beginRequest() {
        dispatchPrecondition(condition: .onQueue(queue))
        inFlight += 1
    }

    func finishRequest() {
        queue.async {
            self.inFlight -= 1
            if self.peerFinished && self.inFlight == 0 { self.closeOnQueue() }
        }
    }

    /// Sends a message (response or notification). Ignored once closed.
    public func send(_ message: RPCMessage) {
        queue.async { self.writeOnQueue(message) }
    }

    /// Sends a notification if the connection subscribed to its topic (see `events.subscribe`).
    public func notify(topic: String, method: String, params: JSONValue?) {
        queue.async {
            guard self.subscribedTopics.contains(topic) else { return }
            self.writeOnQueue(.request(RPCRequest(id: nil, method: method, params: params)))
        }
    }

    public func subscribe(_ topics: Set<String>) {
        queue.async { self.subscribedTopics.formUnion(topics) }
    }

    private func writeOnQueue(_ message: RPCMessage) {
        guard !closed, let data = try? RPCCodec.encode(message) else { return }
        do {
            try UnixSocket.writeAll(fd, data)
        } catch {
            closeOnQueue()
        }
    }

    public func close() {
        queue.async { self.closeOnQueue() }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        if peerFinished { readSource?.resume() }  // a suspended source cannot be cancelled cleanly
        readSource?.cancel()  // closes the descriptor
        readSource = nil
        onClose(self)
    }

    public static func == (lhs: ControlConnection, rhs: ControlConnection) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
