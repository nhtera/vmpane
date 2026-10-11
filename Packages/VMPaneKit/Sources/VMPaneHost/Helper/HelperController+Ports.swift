import Darwin
import Foundation
import VMPaneControl
import VMPaneCore

/// Port forwards. A QEMU guest's live in QEMU's NAT (hostfwd, `QEMUSession+Settings`); a VZ guest's are the
/// helper's own `PortForwarder`, running while the VM runs.
extension HelperController {
    /// VZ forwards start with the VM and stop with it.
    func forwardsFollowState(_ next: VMRunState) {
        switch next {
        case .running:
            guard backend?.kind == .vz, portForwarder == nil,
                let nic = config.network.first(where: { $0.mode == .nat }), let resolver = GuestIPResolver(macAddress: nic.macAddress)
            else { return }
            let hub = agentHub
            let cache = GuestAddressCache()
            let forwarder = PortForwarder { refresh in
                await cache.address(refresh: refresh) {
                    await resolver.resolve(hints: await Self.agentAddressHints(hub, mac: resolver.macAddress))
                }
            }
            portForwarder = forwarder
            let rules = (try? PortRule.rules(config.portForwards)) ?? []
            Task { await forwarder.apply(rules) }
        case .stopped, .error:
            guard let forwarder = portForwarder else { return }
            portForwarder = nil
            Task { await forwarder.stopAll() }
        default:
            break
        }
    }

    /// The running VZ VM's forwards now follow `rules`; true when every one is listening.
    func applyForwards(_ rules: [PortRule]) async -> Bool {
        guard let portForwarder else { return false }
        await portForwarder.apply(rules)
        return await portForwarder.statuses.allSatisfy { if case .failed = $0.status { false } else { true } }
    }

    /// Why the host ports of rules new in `rules` (not in `current`) cannot be opened now, if any can't: a rule
    /// that would fail is refused before it is saved (`-32014`-style "in use").
    static func busyHostPort(_ rules: [PortRule], current: [PortRule]) -> String? {
        for rule in rules
        where !current.contains(where: { $0.proto == rule.proto && $0.hostAddress == rule.hostAddress && $0.hostPort == rule.hostPort }) {
            do {
                close(try Sockets.bound(rule.hostAddress.rawValue, rule.hostPort, stream: rule.proto == .tcp))
            } catch {
                return "\(rule.proto.rawValue) \(rule.hostAddress.rawValue):\(rule.hostPort) cannot be opened on this Mac (\(error))"
            }
        }
        return nil
    }

    /// `vm.ports.list`: each rule with its state. QEMU's forwards are in effect while the VM runs (QEMU refuses
    /// to start, and a live change reports, when one cannot be opened).
    func portsList() async -> Result<JSONValue, RPCError> {
        let statuses: [String: PortForwarder.Status]
        if let portForwarder {
            statuses = Dictionary(uniqueKeysWithValues: await portForwarder.statuses.map { ($0.rule.id, $0.status) })
        } else {
            statuses = [:]
        }
        let running = state == .running || state == .paused
        let rules: [JSONValue] = config.portForwards.map { rule in
            var entry: [String: JSONValue] = [
                "id": .string(rule.id), "proto": .string(rule.proto.rawValue), "hostAddress": .string(rule.hostAddress),
                "hostPort": .int(Int64(rule.hostPort)), "guestPort": .int(Int64(rule.guestPort)), "origin": .string(rule.origin.rawValue),
            ]
            switch (statuses[rule.id], running) {
            case (.listening?, _): entry["status"] = "listening"
            case (.blocked?, _):
                entry["status"] = "blocked"
                entry["reason"] = "macOS Local Network privacy: allow VMPane in System Settings › Privacy & Security › Local Network"
            case (.failed(let reason)?, _):
                entry["status"] = "failed"
                entry["reason"] = .string(reason)
            case (nil, true): entry["status"] = backend?.kind == .qemu ? "listening" : "inactive"
            case (nil, false): entry["status"] = "inactive"
            }
            return .object(entry)
        }
        return .success(["rules": .array(rules), "listening": .array(await guestListening())])
    }

    /// What the guest listens on beyond its own loopback, from the agent (suggestions for new forwards; the
    /// guest's word, so only shown). Empty without an agent that reports ports.
    private func guestListening() async -> [JSONValue] {
        guard let connection = await agentHub.connection, await agentHub.status.peer?.hello.caps?.contains(AgentCap.ports) == true,
            let reply = try? await connection.call(AgentMethod.portsListening, timeout: .seconds(2)),
            case .success(let listening) = RPCParams.decode(AgentPortsListening.self, from: reply.result)
        else { return [] }
        var seen: Set<String> = []
        var ports: [JSONValue] = []
        // DHCP clients (UDP 68, 546) listen too but serve nothing.
        let clients: Set<UInt16> = [68, 546]
        for port in listening.ports
        where !port.address.hasPrefix("127.") && port.address != "::1" && port.port > 0
            && !(port.proto == .udp && clients.contains(port.port))
        {
            guard seen.insert("\(port.proto.rawValue)/\(port.port)").inserted, ports.count < 64 else { continue }
            var entry: [String: JSONValue] = ["proto": .string(port.proto.rawValue), "port": .int(Int64(port.port))]
            if let process = port.process { entry["process"] = .string(String(process.prefix(64))) }
            ports.append(.object(entry))
        }
        return ports
    }

    /// The guest agent's IPv4 addresses on the NAT NIC (matched by MAC), as hints for the resolver.
    static func agentAddressHints(_ hub: AgentHub, mac: String) async -> [String] {
        guard let connection = await hub.connection,
            let reply = try? await connection.call(AgentMethod.netAddrs, timeout: .seconds(2)),
            case .success(let addresses) = RPCParams.decode(AgentNetAddrs.self, from: reply.result)
        else { return [] }
        let matching = addresses.interfaces.filter { $0.mac.flatMap(DHCPLease.canonicalMAC) == mac }
        return (matching.isEmpty ? addresses.interfaces : matching).flatMap { $0.ipv4 ?? [] }.map {
            $0.split(separator: "/").first.map(String.init) ?? $0
        }
    }
}

/// The guest's last verified address, shared by a VM's forwards; looked up again on request (one lookup at a time).
actor GuestAddressCache {
    private var address: IPv4?
    private var lookup: Task<IPv4?, Never>?

    func address(refresh: Bool, resolve: @escaping @Sendable () async -> IPv4?) async -> IPv4? {
        if !refresh, let address { return address }
        if let lookup { return await lookup.value }
        let task = Task { await resolve() }
        lookup = task
        let found = await task.value
        lookup = nil
        address = found
        return found
    }
}
