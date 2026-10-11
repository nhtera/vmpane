import Darwin
import Foundation
import VMPaneCore
import os

/// Port forwards into a VZ NAT guest (QEMU forwards live in QEMU's own NAT): a host socket per rule, and per
/// client a connection to the guest, copied both ways. The guest's address is resolved (and verified) when a
/// client arrives, and looked up again when the guest does not answer there.
///
/// Kernel sockets with a thread per direction, not Network.framework: an `NWConnection` whose write side is
/// closed fails (ENETDOWN) while its peer is still sending, and a forwarder must pass half-closes on.
/// macOS 15's Local Network privacy covers connections into the NAT subnet: until the user allows VMPane, they
/// fail, and the rule reports `blocked`.
public actor PortForwarder {
    public enum Status: Sendable, Equatable {
        case listening
        /// The host port could not be opened (in use, not permitted).
        case failed(String)
        /// Connections to the guest are refused by Local Network privacy.
        case blocked
    }

    public struct RuleStatus: Sendable, Equatable {
        public let rule: PortRule
        public let status: Status
    }

    static let log = Logger(subsystem: VMPane.SigningIdentifier.helper, category: "ports")
    private let target: @Sendable (_ refresh: Bool) async -> IPv4?
    private var rules: [PortRule] = []
    private var forwards: [String: Forward] = [:]
    private var failures: [String: String] = [:]
    private var blocked: Set<String> = []

    /// `target(refresh)` gives the guest's address; `refresh` asks to look again instead of using a cached one.
    public init(target: @escaping @Sendable (_ refresh: Bool) async -> IPv4?) {
        self.target = target
    }

    /// Makes the host sockets match `rules`: new and changed rules start listening, removed ones stop (their
    /// ports are free when this returns). A rule whose port cannot be opened is `failed`; the next apply retries it.
    public func apply(_ rules: [PortRule]) {
        for (id, forward) in forwards where !rules.contains(forward.rule) {
            forward.stop()
            forwards[id] = nil
        }
        blocked.formIntersection(forwards.keys)
        failures = [:]
        for rule in rules where forwards[rule.id] == nil {
            do {
                forwards[rule.id] = try Forward(rule: rule, forwarder: self)
            } catch {
                Self.log.error("forward \(rule.id, privacy: .public): \(String(describing: error), privacy: .public)")
                failures[rule.id] = String(describing: error)
            }
        }
        self.rules = rules
    }

    public func stopAll() { apply([]) }

    public var statuses: [RuleStatus] {
        rules.map { rule in
            if let failure = failures[rule.id] { return RuleStatus(rule: rule, status: .failed(failure)) }
            return RuleStatus(rule: rule, status: blocked.contains(rule.id) ? .blocked : .listening)
        }
    }

    nonisolated func guestAddress(refresh: Bool) async -> IPv4? { await target(refresh) }

    func noteBlocked(_ id: String, _ isBlocked: Bool) {
        if isBlocked { blocked.insert(id) } else { blocked.remove(id) }
    }
}

/// One rule's host socket and its clients. The loops wait on the socket and a wake pipe: `stop()` makes the
/// pipe readable, and the loop thread closes the host socket itself (closing a descriptor another thread is
/// blocked on neither wakes it reliably nor keeps its number from being reused).
private final class Forward: @unchecked Sendable {
    let rule: PortRule
    private weak var forwarder: PortForwarder?
    private let socket: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let closed = DispatchSemaphore(value: 0)
    /// UDP reply threads (they send from the host socket, so it closes after them).
    private let replyThreads = DispatchGroup()
    private let lock = NSLock()
    private var stopped = false
    private var open: Set<Int32> = []
    private var flows: [Sockets.Address: Int32] = [:]
    /// Descriptors per rule (two per TCP client, one per UDP flow).
    static let maxOpen = 512

    init(rule: PortRule, forwarder: PortForwarder) throws {
        self.rule = rule
        self.forwarder = forwarder
        socket = try Sockets.bound(rule.hostAddress.rawValue, rule.hostPort, stream: rule.proto == .tcp)
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            Darwin.close(socket)
            throw SocketError(call: "pipe", code: errno)
        }
        (wakeRead, wakeWrite) = (pipeFDs[0], pipeFDs[1])
        let thread = Thread { [self] in
            if rule.proto == .tcp { acceptLoop() } else { datagramLoop() }
            replyThreads.wait()
            Darwin.close(socket)
            closed.signal()
        }
        thread.name = "app.vmpane.ports.\(rule.id)"
        thread.start()
    }

    deinit {
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    /// Stops listening (the host port is free when this returns) and ends every client.
    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
            for fd in open { Darwin.shutdown(fd, SHUT_RDWR) }
        }
        _ = closed.wait(timeout: .now() + 5)
    }

    /// Records a client-side descriptor, so `stop()` can end it; false once stopped.
    private func track(_ fd: Int32) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            open.insert(fd)
            return true
        }
    }

    private func release(_ fd: Int32) {
        lock.withLock { _ = open.remove(fd) }
        Darwin.close(fd)
    }

    // MARK: - TCP

    private func acceptLoop() {
        while Sockets.readable(socket, wake: wakeRead) {
            let client = Darwin.accept(socket, nil, nil)
            if client < 0 {
                if errno == EMFILE || errno == ENFILE { usleep(100_000) }  // out of descriptors: no busy loop
                continue  // or the client gave up meanwhile
            }
            Sockets.noSigPipe(client)
            guard lock.withLock({ open.count }) < Self.maxOpen else {
                Darwin.close(client)  // a flood (e.g. a scan of an all-interfaces rule) is turned away
                continue
            }
            guard track(client) else {
                Darwin.close(client)
                return
            }
            Task { await self.serve(client) }
        }
    }

    private func serve(_ client: Int32) async {
        defer { release(client) }
        guard let forwarder else { return }
        var refreshed = false
        var address = await forwarder.guestAddress(refresh: false)
        while let guestAddress = address {
            switch await Sockets.connect(to: guestAddress, rule.guestPort, timeout: 10) {
            case .success(let guest):
                await forwarder.noteBlocked(rule.id, false)
                guard track(guest) else {
                    Darwin.close(guest)
                    return
                }
                await Sockets.splice(client, guest)
                release(guest)
                return
            case .failure(let error):
                if error.code == EHOSTUNREACH, await Sockets.localNetworkDenied(guestAddress, rule.guestPort) {
                    await forwarder.noteBlocked(rule.id, true)
                    return
                }
                // The guest may have a new address (a new lease): look once more.
                guard !refreshed else { return }
                refreshed = true
                address = await forwarder.guestAddress(refresh: true)
            }
        }
    }

    // MARK: - UDP

    /// Datagrams from each client address go out on a connected socket of their own, whose replies go back to
    /// that client. A flow idle for 60 s is closed.
    private func datagramLoop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Sockets.readable(socket, wake: wakeRead) {
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &length) }
            }
            if count < 0 { continue }
            let client = Sockets.Address(from, length)
            let packet = Array(buffer[0..<count])
            if let flow = lock.withLock({ flows[client] }) {
                _ = packet.withUnsafeBytes { Darwin.send(flow, $0.baseAddress, $0.count, 0) }
                continue
            }
            Task { await self.startFlow(client, first: packet) }
        }
    }

    private func startFlow(_ client: Sockets.Address, first packet: [UInt8]) async {
        guard let forwarder, let address = await forwarder.guestAddress(refresh: false),
            let flow = try? Sockets.udpConnected(to: address, rule.guestPort)
        else { return }
        let registered = lock.withLock {
            guard !stopped, flows[client] == nil, open.count < Self.maxOpen else { return false }
            flows[client] = flow
            open.insert(flow)
            replyThreads.enter()
            return true
        }
        guard registered else {
            Darwin.close(flow)
            return
        }
        _ = packet.withUnsafeBytes { Darwin.send(flow, $0.baseAddress, $0.count, 0) }
        let thread = Thread { [self] in
            replies(flow, to: client)
            lock.withLock { flows[client] = nil }
            release(flow)
            replyThreads.leave()
        }
        thread.start()
    }

    private func replies(_ flow: Int32, to client: Sockets.Address) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Sockets.readable(flow, wake: wakeRead, timeout: .seconds(60)) {  // false when idle or stopped
            let count = Darwin.recv(flow, &buffer, buffer.count, 0)
            if count < 0 { continue }
            client.withSockaddr { address, length in _ = sendto(socket, buffer, count, 0, address, length) }
        }
    }
}
