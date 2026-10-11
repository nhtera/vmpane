import Darwin
import Foundation
import Network

/// A POSIX error from a socket call, named.
struct SocketError: Error, CustomStringConvertible {
    let call: String
    let code: Int32
    var description: String { "\(call): \(String(cString: strerror(code)))" }
}

/// The socket plumbing of port forwarding. Every blocking call runs on a thread of its own or a GCD thread,
/// never on the cooperative pool.
enum Sockets {
    /// A client's socket address, usable as a key.
    struct Address: Hashable, @unchecked Sendable {
        let bytes: [UInt8]

        init(_ storage: sockaddr_storage, _ length: socklen_t) {
            var storage = storage
            bytes = withUnsafeBytes(of: &storage) { Array($0.prefix(Int(length))) }
        }

        func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: bytes) }
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(bytes.count)) }
            }
        }
    }

    /// A listening TCP socket or a bound UDP socket on `host`:`port` (an IPv4 or IPv6 literal).
    static func bound(_ host: String, _ port: UInt16, stream: Bool) throws -> Int32 {
        // SO_REUSEADDR lets a specific address share a port with another program's wildcard listener: that
        // program's loopback clients would reach the guest instead. Something answering there means "in use".
        if stream, accepts(host == "0.0.0.0" ? "127.0.0.1" : host, port) { throw SocketError(call: "bind", code: EADDRINUSE) }
        let isV6 = host.contains(":")
        let fd = socket(isV6 ? AF_INET6 : AF_INET, stream ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var enabled: Int32 = 1
        if stream { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) }  // not SO_REUSEPORT
        noSigPipe(fd)
        let result: Int32
        if isV6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            inet_pton(AF_INET6, host, &address.sin6_addr)
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size))
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &address.sin_addr)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if result != 0 || (stream && listen(fd, 128) != 0) {
            let error = SocketError(call: result != 0 ? "bind" : "listen", code: errno)
            close(fd)
            throw error
        }
        return fd
    }

    /// Whether something accepts TCP connections on loopback `host`:`port` (an immediate local answer).
    static func accepts(_ host: String, _ port: UInt16) -> Bool {
        let isV6 = host.contains(":")
        let fd = socket(isV6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        noSigPipe(fd)
        if isV6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            inet_pton(AF_INET6, host, &address.sin6_addr)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            } == 0
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    static func noSigPipe(_ fd: Int32) {
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Whether `fd` became readable before `wake` did (or `timeout` passed: false).
    static func readable(_ fd: Int32, wake: Int32, timeout: Duration? = nil) -> Bool {
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        let milliseconds = timeout.map { Int32($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) } ?? -1
        while true {
            let ready = poll(&fds, 2, milliseconds)
            if ready < 0, errno == EINTR { continue }
            return ready > 0 && fds[1].revents == 0 && fds[0].revents != 0
        }
    }

    static func ipv4(_ address: IPv4, _ port: UInt16) -> sockaddr_in {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = address.value.bigEndian
        return target
    }

    /// A TCP connection to `address`:`port`, or the error that stopped it (ETIMEDOUT after `timeout` seconds).
    static func connect(to address: IPv4, _ port: UInt16, timeout: Int32) async -> Result<Int32, SocketError> {
        await offPool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return .failure(SocketError(call: "socket", code: errno)) }
            noSigPipe(fd)
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var target = ipv4(address, port)
            let started = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var code: Int32 = started == 0 ? 0 : errno
            if code == EINPROGRESS {
                var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pending, 1, timeout * 1000) <= 0 {
                    code = ETIMEDOUT
                } else {
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length)
                }
            }
            guard code == 0 else {
                close(fd)
                return .failure(SocketError(call: "connect", code: code))
            }
            _ = fcntl(fd, F_SETFL, flags)
            return .success(fd)
        }
    }

    /// A UDP socket connected to `address`:`port`.
    static func udpConnected(to address: IPv4, _ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var target = ipv4(address, port)
        let result = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let error = SocketError(call: "connect", code: errno)
            close(fd)
            throw error
        }
        return fd
    }

    /// Copies `a` ⇄ `b` until both directions have ended, a thread per direction. A direction that reaches
    /// end-of-stream half-closes its destination (the other direction keeps going); an error ends both.
    /// Blocking writes are the backpressure: a slow reader slows its writer.
    static func splice(_ a: Int32, _ b: Int32) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (source, sink) in [(a, b), (b, a)] {
                group.enter()
                let thread = Thread {
                    copy(from: source, to: sink, other: source == a ? b : a)
                    group.leave()
                }
                thread.stackSize = 256 * 1024
                thread.start()
            }
            group.notify(queue: .global()) { done.resume() }
        }
    }

    private static func copy(from source: Int32, to sink: Int32, other: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(source, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            if count == 0 {
                shutdown(sink, SHUT_WR)
                return
            }
            guard count > 0, writeAll(sink, buffer, count) else {
                shutdown(source, SHUT_RDWR)
                shutdown(sink, SHUT_RDWR)
                return
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let wrote = buffer.withUnsafeBytes { send(fd, $0.baseAddress.map { $0 + sent }, count - sent, 0) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return false }
            sent += wrote
        }
        return true
    }

    /// Whether Local Network privacy is what keeps this process from `address` (BSD sockets only see "no route
    /// to host"; Network.framework says why).
    static func localNetworkDenied(_ address: IPv4, _ port: UInt16) async -> Bool {
        guard let host = Network.IPv4Address(address.description), let port = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: .ipv4(host), port: port, using: .tcp)
        let answer = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            let queue = DispatchQueue(label: "app.vmpane.ports.privacy")
            connection.stateUpdateHandler = { state in
                switch state {
                case .waiting, .failed:
                    if once.claim() { done.resume(returning: connection.currentPath?.unsatisfiedReason == .localNetworkDenied) }
                case .ready:
                    if once.claim() { done.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { if once.claim() { done.resume(returning: false) } }
        }
        connection.cancel()
        return answer
    }

    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: work()) } }
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
