import Darwin
import Foundation
import VMPaneCore

/// A connected stream socket to the guest agent (vsock from VZ, a QEMU chardev socket, or a test socket).
/// Reads run on a dedicated thread and hand over one buffer at a time: the next read waits until the previous
/// buffer was processed, so a guest that sends faster than the host consumes is held back by the socket itself.
/// Writes run on a serial queue in the order they were submitted. The descriptor is closed only once both the
/// reader thread has stopped and `close` was called, so neither side ever touches a reused descriptor.
final class AgentSocket: @unchecked Sendable {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "app.vmpane.agent.write")
    private let lock = NSLock()
    private let handoff = DispatchSemaphore(value: 0)
    private var closed = false
    private var reading = false

    /// Takes ownership of `fd`.
    init(fd: Int32) {
        self.fd = fd
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// Bytes as they arrive; ends at EOF, on an error or after `close`. Call `consumed()` after each element.
    func reads() -> (stream: AsyncStream<Data>, consumed: @Sendable () -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let started = lock.withLock { () -> Bool in
            guard !closed, !reading else { return false }
            reading = true
            return true
        }
        guard started else {
            continuation.finish()
            return (stream, {})
        }
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 256 << 10)
            while !isClosed {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                continuation.yield(Data(buffer[0..<count]))
                handoff.wait()
            }
            continuation.finish()
            let release = lock.withLock { () -> Bool in
                reading = false
                return closed
            }
            if release { closeDescriptor() }
        }
        thread.name = "app.vmpane.agent.read"
        thread.start()
        return (stream, { [handoff] in handoff.signal() })
    }

    /// Queues `data` behind everything submitted before it, now; `completion` runs once it is written or failed.
    func enqueue(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        writeQueue.async { [self] in
            guard !isClosed else { return completion(POSIXError(.EPIPE)) }
            do {
                try UnixSocket.writeAll(fd, data)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Writes `data` after everything submitted before it; resumes once it is written.
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(data) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    /// Ends both directions; the reader sees EOF. Idempotent.
    func close() {
        let (first, readerRunning) = lock.withLock { () -> (Bool, Bool) in
            defer { closed = true }
            return (!closed, reading)
        }
        guard first else { return }
        shutdown(fd, SHUT_RDWR)
        handoff.signal()  // a reader waiting for its consumer stops now
        if !readerRunning { closeDescriptor() }
    }

    /// After queued writes (which fail fast on the shut-down socket).
    private func closeDescriptor() {
        let fd = fd
        writeQueue.async { Darwin.close(fd) }
    }
}
