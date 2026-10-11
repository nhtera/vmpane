import Darwin
import Foundation
import Network
import Synchronization
import Testing
import VMPaneCore

@testable import VMPaneHost

/// A stand-in guest service on 127.0.0.1: echoes TCP streams and UDP datagrams.
private final class EchoServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "echo")
    /// Accepted connections, kept alive (a released NWConnection is torn down, cutting its peer off).
    private let connections = Mutex<[NWConnection]>([])

    init(udp: Bool = false) async throws {
        listener = try NWListener(using: udp ? .udp : .tcp, on: .any)
        listener.newConnectionHandler = { [weak self, queue] connection in
            self?.connections.withLock { $0.append(connection) }
            connection.start(queue: queue)
            Self.echo(connection, udp: udp)
        }
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            let once = Mutex(false)
            listener.stateUpdateHandler = { state in
                if case .ready = state,
                    !once.withLock({
                        let was = $0; $0 = true; return was
                    })
                {
                    ready.resume()
                }
            }
            listener.start(queue: queue)
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private static func echo(_ connection: NWConnection, udp: Bool) {
        let handle: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, context, ended, error in
            let complete = ended && (udp || context?.isFinal == true)
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in if !complete || udp { echo(connection, udp: udp) } })
            }
            if complete && !udp { connection.send(content: nil, contentContext: .defaultStream, isComplete: true, completion: .idempotent) }
            if error != nil { connection.cancel() }
            if data?.isEmpty ?? true, !complete, error == nil { echo(connection, udp: udp) }
        }
        if udp {
            connection.receiveMessage(completion: handle)
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: handle)
        }
    }

    deinit {
        listener.cancel()
        connections.withLock { $0.forEach { $0.cancel() } }
    }
}

/// A kernel-socket TCP echo server on 127.0.0.1 (one thread per client), the way a real guest service behaves.
private final class SocketEcho: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
            sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        Darwin.listen(fd, 16)
        let server = fd
        Thread.detachNewThread {
            while true {
                let client = accept(server, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let count = recv(client, &buffer, buffer.count, 0)
                        if count <= 0 { break }
                        var sent = 0
                        while sent < count {
                            let wrote = buffer.withUnsafeBytes { send(client, $0.baseAddress.map { $0 + sent }, count - sent, 0) }
                            if wrote <= 0 { break }
                            sent += wrote
                        }
                    }
                    shutdown(client, SHUT_WR)
                    var drain = [UInt8](repeating: 0, count: 1024)
                    while recv(client, &drain, drain.count, 0) > 0 {}
                    close(client)
                }
            }
        }
    }

    deinit { close(fd) }
}

/// Blocking socket work off the cooperative pool (see FakeAgent).
private func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: work()) } }
}

private func freePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
        sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return UInt16(bigEndian: address.sin_port)
}

/// Connects to 127.0.0.1:`port`, writes `payload`, half-closes, reads until EOF. Nil if the connection fails.
private func roundTrip(_ port: UInt16, _ payload: Data, udp: Bool = false) -> Data? {
    let fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
    defer { close(fd) }
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    let connected = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return nil }
    if udp {
        _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }
    let writer = DispatchQueue(label: "writer")
    writer.async {
        var sent = 0
        payload.withUnsafeBytes { bytes in
            while sent < bytes.count {
                let count = send(fd, bytes.baseAddress.map { $0 + sent }, bytes.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
        shutdown(fd, SHUT_WR)
    }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count <= 0 { break }
        received.append(contentsOf: buffer[0..<count])
    }
    writer.sync {}
    return received
}

private func rule(_ id: String, _ proto: PortForwardConfig.Proto = .tcp, host: UInt16, guest: UInt16) throws -> PortRule {
    try PortRule(
        PortForwardConfig(id: id, proto: proto, hostAddress: "127.0.0.1", hostPort: Int(host), guestPort: Int(guest), origin: .user))
}

private let loopback = IPv4(127, 0, 0, 1)

@Test func tcpStreamsArriveIntactBothWays() async throws {
    let echo = SocketEcho()
    let forwarder = PortForwarder { _ in loopback }
    let port = freePort()
    await forwarder.apply([try rule("echo", host: port, guest: echo.port)])
    #expect(await forwarder.statuses.map(\.status) == [.listening])
    let payload = Data((0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let started = Date()
    let back = await offPool { roundTrip(port, payload) }
    let seconds = Date().timeIntervalSince(started)
    #expect(back == payload)
    print("port forward: 8 MiB echoed in \(String(format: "%.3f", seconds)) s")
    await forwarder.stopAll()
    withExtendedLifetime(echo) {}  // its deinit would end the guest side early
}

@Test func udpDatagramsAreForwarded() async throws {
    let echo = try await EchoServer(udp: true)
    let forwarder = PortForwarder { _ in loopback }
    let port = freePort()
    await forwarder.apply([try rule("dns", .udp, host: port, guest: echo.port)])
    let back = await offPool { roundTrip(port, Data("ping".utf8), udp: true) }
    #expect(back == Data("ping".utf8))
    await forwarder.stopAll()
    withExtendedLifetime(echo) {}
}

@Test func aBusyHostPortFailsAndRemovedRulesStopListening() async throws {
    let echo = try await EchoServer()
    let forwarder = PortForwarder { _ in loopback }
    let port = freePort()
    await forwarder.apply([try rule("a", host: port, guest: echo.port)])
    let other = PortForwarder { _ in loopback }
    await other.apply([try rule("b", host: port, guest: echo.port)])
    guard case .failed? = await other.statuses.first?.status else {
        Issue.record("a second listener on the same port should fail")
        return
    }
    await forwarder.apply([])
    #expect(await forwarder.statuses.isEmpty)
    #expect(await offPool { roundTrip(port, Data("x".utf8)) } == nil, "nothing listens any more")
    withExtendedLifetime(echo) {}
}

/// A refused guest port closes the client and looks the guest's address up again once.
@Test func aRefusedGuestPortClosesTheClientAfterOneFreshLookup() async throws {
    let lookups = Mutex<[Bool]>([])
    let forwarder = PortForwarder { refresh in
        lookups.withLock { $0.append(refresh) }
        return loopback
    }
    let port = freePort()
    await forwarder.apply([try rule("closed", host: port, guest: freePort())])
    let started = Date()
    let back = await offPool { roundTrip(port, Data("x".utf8)) }
    #expect(back?.isEmpty ?? true)
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(lookups.withLock { $0 } == [false, true])
    await forwarder.stopAll()
}
