import Darwin
import Foundation
import VMPaneCore

public enum QMPError: Error, Equatable, Sendable, CustomStringConvertible {
    case connectionClosed
    case timedOut(command: String)
    /// QEMU sent something QMP does not allow (bad greeting, oversized line, malformed message). The
    /// connection is closed: a QEMU that breaks the protocol may be controlled by the guest.
    case protocolViolation(String)
    /// The command ran and QEMU answered with an error.
    case commandFailed(command: String, errorClass: String, description: String)

    public var description: String {
        switch self {
        case .connectionClosed: "the QMP connection closed"
        case .timedOut(let command): "QMP \(command) timed out"
        case .protocolViolation(let what): "QMP protocol violation: \(what)"
        case .commandFailed(let command, let errorClass, let description): "QMP \(command) failed (\(errorClass)): \(description)"
        }
    }
}

/// An asynchronous QMP event (`SHUTDOWN`, `STOP`, `BLOCK_IO_ERROR`, …).
public struct QMPEvent: Sendable, Equatable {
    public let name: String
    public let data: JSONValue
    public let timestamp: Date?

    public init(name: String, data: JSONValue = .object([:]), timestamp: Date? = nil) {
        self.name = name
        self.data = data
        self.timestamp = timestamp
    }
}

/// A client for QEMU's QMP socket: newline-delimited JSON, a greeting, `qmp_capabilities`, then commands
/// correlated by id and events in between. Everything QEMU sends is treated as untrusted: lines are capped,
/// messages are decoded strictly, and the event buffer is bounded.
public final class QMPClient: @unchecked Sendable {
    public static let maxLineBytes = 1 << 20
    /// Events kept while nobody reads them (the oldest are dropped first).
    public static let eventBufferLimit = 1024

    private let fd: Int32
    private let queue = DispatchQueue(label: "app.vmpane.qmp")
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer(maxLineBytes: QMPClient.maxLineBytes)
    private var nextID: Int64 = 1
    private var pending: [Int64: (command: String, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var greetingContinuation: CheckedContinuation<JSONValue, Error>?
    private var greetingValue: JSONValue?
    private var closed = false
    private let eventContinuation: AsyncStream<QMPEvent>.Continuation

    /// Events in arrival order. Finishes when the connection closes. Single consumer.
    public let events: AsyncStream<QMPEvent>

    private init(fd: Int32) {
        self.fd = fd
        (events, eventContinuation) = AsyncStream.makeStream(of: QMPEvent.self, bufferingPolicy: .bufferingNewest(Self.eventBufferLimit))
    }

    /// Connects (retrying while QEMU has not created the socket yet), reads the greeting and enters
    /// command mode. Returns once commands can be sent.
    public static func connect(to socket: URL, timeout: Duration = .seconds(10)) async throws -> QMPClient {
        let deadline = ContinuousClock.now + timeout
        while true {
            let fd = try UnixSocket.make()
            do {
                try UnixSocket.connect(fd, to: UnixSocketAddress(socket))
            } catch let error as POSIXError where [.ENOENT, .ECONNREFUSED].contains(error.code) && ContinuousClock.now < deadline {
                Darwin.close(fd)
                try await Task.sleep(for: .milliseconds(50))
                continue
            } catch {
                Darwin.close(fd)
                throw error
            }
            // A QEMU that stops reading (perhaps the guest's now) must not block the helper's commands, `quit`
            // included: a write that waits this long fails and closes the connection.
            var stuck = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stuck, socklen_t(MemoryLayout<timeval>.size))
            let client = QMPClient(fd: fd)
            client.start()
            do {
                try await client.handshake(timeout: max(deadline - .now, .seconds(1)))
            } catch {
                client.close()
                throw error
            }
            return client
        }
    }

    /// QEMU's version from the greeting (`{"qemu": {"major": …}, "package": …}`).
    public var version: JSONValue? { queue.sync { greetingValue?["QMP"]?["version"] } }

    private func handshake(timeout: Duration) async throws {
        let greeting = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let greeting = self.greetingValue {
                    continuation.resume(returning: greeting)
                } else if self.closed {
                    continuation.resume(throwing: QMPError.connectionClosed)
                } else {
                    self.greetingContinuation = continuation
                    self.queue.asyncAfter(deadline: .now() + timeout.seconds) {
                        guard let waiting = self.greetingContinuation else { return }
                        self.greetingContinuation = nil
                        waiting.resume(throwing: QMPError.timedOut(command: "greeting"))
                    }
                }
            }
        }
        guard greeting["QMP"]?.objectValue != nil else { throw QMPError.protocolViolation("no greeting") }
        _ = try await execute("qmp_capabilities")
    }

    private func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    /// Runs `command` and returns its `return` value; throws `QMPError.commandFailed` for an error answer.
    @discardableResult
    public func execute(_ command: String, _ arguments: [String: JSONValue]? = nil, timeout: Duration = .seconds(5)) async throws
        -> JSONValue
    {
        let id = queue.sync { () -> Int64 in
            defer { nextID += 1 }
            return nextID
        }
        var message: [String: JSONValue] = ["execute": .string(command), "id": .int(id)]
        if let arguments { message["arguments"] = .object(arguments) }
        let line = try JSONEncoder().encode(JSONValue.object(message)) + [0x0A]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.closed else { return continuation.resume(throwing: QMPError.connectionClosed) }
                    if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
                    do {
                        try UnixSocket.writeAll(self.fd, line)
                    } catch {
                        self.closeOnQueue()
                        return continuation.resume(throwing: QMPError.connectionClosed)
                    }
                    self.pending[id] = (command, continuation)
                    self.queue.asyncAfter(deadline: .now() + timeout.seconds) {
                        self.pending.removeValue(forKey: id)?.continuation.resume(throwing: QMPError.timedOut(command: command))
                    }
                }
            }
        } onCancel: {
            queue.async { self.pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
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
                closeOnQueue(.protocolViolation("line longer than \(Self.maxLineBytes) bytes"))
                return
            }
            do {
                try handle(try QMPMessage.decode(line))
            } catch let error as QMPError {
                closeOnQueue(error)
                return
            } catch {
                closeOnQueue(.protocolViolation(String(describing: error)))
                return
            }
        }
    }

    private func handle(_ message: QMPMessage) throws {
        switch message {
        case .greeting(let value):
            guard greetingValue == nil else { throw QMPError.protocolViolation("second greeting") }
            greetingValue = value
            greetingContinuation?.resume(returning: value)
            greetingContinuation = nil
        case .event(let event):
            eventContinuation.yield(event)
        case .success(let id, let value):
            guard let id else { return }  // QEMU answers without an id only to malformed requests, which we never send
            pending.removeValue(forKey: id)?.continuation.resume(returning: value)
        case .failure(let id, let errorClass, let description):
            guard let id, let waiting = pending.removeValue(forKey: id) else { return }
            waiting.continuation.resume(
                throwing: QMPError.commandFailed(command: waiting.command, errorClass: errorClass, description: description))
        }
    }

    public func close() {
        queue.sync { closeOnQueue() }
    }

    private func closeOnQueue(_ reason: QMPError = .connectionClosed) {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        for waiting in pending.values { waiting.continuation.resume(throwing: reason) }
        pending.removeAll()
        greetingContinuation?.resume(throwing: reason)
        greetingContinuation = nil
        eventContinuation.finish()
    }

    deinit {
        if !closed {
            readSource?.cancel()
            eventContinuation.finish()
        }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
