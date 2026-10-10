import Darwin
import Foundation
import VMPaneCore

/// Text lines a guest writes to a QEMU socket chardev (the `app.vmpane.agent.0` virtio-serial port, whose host end
/// is `run/<sid>/agent.sock`). QEMU listens; this connects, and reconnects whenever QEMU restarts, until `stop`.
/// The bytes come from the guest: lines are capped (a longer one drops the connection) and must be UTF-8.
public final class GuestLineReader: @unchecked Sendable {
    public static let maxLineBytes = 4096

    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let socket: URL
    private let lock = NSLock()
    private var stopped = false
    private var fd: Int32 = -1

    public init(socket: URL) {
        self.socket = socket
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(256))
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "app.vmpane.guest-lines"
        thread.start()
    }

    public func stop() {
        lock.withLock {
            stopped = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
        continuation.finish()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func run() {
        while !isStopped {
            guard let connected = connect() else {
                usleep(500_000)
                continue
            }
            read(connected)
            lock.withLock { fd = -1 }
            close(connected)
        }
    }

    private func connect() -> Int32? {
        guard let socketFD = try? UnixSocket.make() else { return nil }
        guard (try? UnixSocket.connect(socketFD, to: UnixSocketAddress(socket))) != nil else {
            close(socketFD)
            return nil
        }
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            fd = socketFD
            return true
        }
        guard accepted else {
            close(socketFD)
            return nil
        }
        return socketFD
    }

    private func read(_ socketFD: Int32) {
        var framer = LineFramer(maxLineBytes: Self.maxLineBytes)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            for event in framer.append(Data(buffer[0..<count])) {
                guard case .line(let line) = event else { return }  // too long: drop the connection
                guard let text = String(bytes: line, encoding: .utf8) else { continue }
                continuation.yield(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
