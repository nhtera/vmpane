import Darwin
import Foundation
import VMPaneCore

public enum ControlClientError: Error, Equatable, Sendable {
    case connectionClosed
    case timedOut(method: String)
}

/// JSON-RPC client for a helper's control socket (used by the app, the CLI and the MCP server).
public final class UDSClient: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "app.vmpane.control.client")
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer(maxLineBytes: RPCCodec.maxResponseLineBytes)
    private var nextID: Int64 = 1
    private var pending: [RPCID: CheckedContinuation<RPCResponse, Error>] = [:]
    private var closed = false
    private let notificationContinuation: AsyncStream<RPCRequest>.Continuation

    /// Notifications from the helper (after `events.subscribe`).
    public let notifications: AsyncStream<RPCRequest>

    private init(fd: Int32) {
        self.fd = fd
        (notifications, notificationContinuation) = AsyncStream.makeStream(of: RPCRequest.self)
    }

    public static func connect(to socketURL: URL) throws -> UDSClient {
        let fd = try UnixSocket.make()
        do {
            try UnixSocket.connect(fd, to: UnixSocketAddress(socketURL))
        } catch {
            Darwin.close(fd)
            throw error
        }
        let client = UDSClient(fd: fd)
        client.start()
        return client
    }

    private func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    /// Calls `method` and returns its result; throws `RPCError` for error responses.
    public func call(_ method: String, params: JSONValue? = nil, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let response = try await send(method, params: params, timeout: timeout)
        switch response.outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    /// Sends a notification (no response).
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        let data = try RPCCodec.encode(.request(RPCRequest(id: nil, method: method, params: params)))
        try queue.sync {
            guard !closed else { throw ControlClientError.connectionClosed }
            try UnixSocket.writeAll(fd, data)
        }
    }

    private func send(_ method: String, params: JSONValue?, timeout: Duration) async throws -> RPCResponse {
        let id = queue.sync { () -> RPCID in
            defer { nextID += 1 }
            return RPCID.int(nextID)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.closed else {
                        continuation.resume(throwing: ControlClientError.connectionClosed)
                        return
                    }
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try UnixSocket.writeAll(self.fd, RPCCodec.encode(.request(RPCRequest(id: id, method: method, params: params))))
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    self.pending[id] = continuation
                    self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                        self.pending.removeValue(forKey: id)?.resume(throwing: ControlClientError.timedOut(method: method))
                    }
                }
            }
        } onCancel: {
            queue.async { self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 {
            if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
            closeOnQueue()
            return
        }
        for event in framer.append(Data(buffer[0..<count])) {
            guard case .line(let line) = event else {
                closeOnQueue()
                return
            }
            switch RPCCodec.decode(line) {
            case .success(.response(let response)):
                if let id = response.id { pending.removeValue(forKey: id)?.resume(returning: response) }
            case .success(.request(let request)) where request.isNotification:
                notificationContinuation.yield(request)
            default:
                break
            }
        }
    }

    public func close() {
        queue.sync { closeOnQueue() }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        for continuation in pending.values { continuation.resume(throwing: ControlClientError.connectionClosed) }
        pending.removeAll()
        notificationContinuation.finish()
    }

    deinit {
        if !closed {
            readSource?.cancel()
            notificationContinuation.finish()
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
