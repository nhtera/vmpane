import Darwin
import Foundation

/// The IPv4 address of a VZ NAT guest, for port forwards to connect to (Red Team #13). Nothing the guest says
/// is trusted by itself: DHCP leases and the agent's `net.addrs` only nominate addresses, and an address is used
/// only when this Mac's ARP table maps it to the VM's own MAC on a NAT bridge. Loopback, link-local, the host's
/// own addresses and anything outside the NAT subnets are never nominated.
///
/// Leases alone cannot do it: guests that identify by DUID (systemd-networkd) are recorded without a MAC.
public struct GuestIPResolver: Sendable {
    /// The VM's NAT MAC address, canonical (`aa:bb:…`).
    public let macAddress: String
    var leases: @Sendable () -> [DHCPLease] = { DHCPLease.read() }
    var neighbours: @Sendable () -> [ARPEntry] = { ARPEntry.read() }
    var subnets: @Sendable () -> [HostSubnet] = { HostSubnet.natBridges() }
    /// Makes the host ARP for `address` (a datagram to the discard port), so a guest that has not talked to the
    /// host lately gets an entry.
    var probe: @Sendable (IPv4) -> Void = { GuestIPResolver.sendProbe(to: $0) }
    var settle: Duration = .milliseconds(250)
    var now: @Sendable () -> Date = { Date() }

    public init?(macAddress: String) {
        guard let mac = DHCPLease.canonicalMAC(macAddress) else { return nil }
        self.macAddress = mac
    }

    /// The guest's verified address, or nil. `hints` are addresses the guest's agent reported. `refresh` skips
    /// the ARP shortcut (an old entry may name the guest's previous address) and probes the candidates.
    public func resolve(hints: [String] = [], refresh: Bool = false) async -> IPv4? {
        let subnets = subnets()
        guard !subnets.isEmpty else { return nil }
        if !refresh, let known = Self.verified(macAddress, among: nil, neighbours(), subnets) { return known }
        let candidates = Self.candidates(mac: macAddress, leases: leases(), hints: hints, subnets: subnets, now: now())
        guard !candidates.isEmpty else { return nil }
        for candidate in candidates { probe(candidate) }
        try? await Task.sleep(for: settle)
        return Self.verified(macAddress, among: candidates, neighbours(), subnets)
    }

    /// The address the ARP table gives `mac` on a NAT bridge (one of `candidates`, when given).
    static func verified(_ mac: String, among candidates: [IPv4]?, _ entries: [ARPEntry], _ subnets: [HostSubnet]) -> IPv4? {
        entries.first { entry in
            entry.macAddress == mac && (candidates?.contains(entry.ipAddress) ?? true)
                && subnets.contains { $0.interface == entry.interface && acceptable(entry.ipAddress, in: $0) }
        }?.ipAddress
    }

    /// Addresses worth probing, best first: an unexpired lease for our MAC, then the agent's hints, then other
    /// unexpired leases without a MAC (DUID clients) in the NAT subnets. Addresses leased to another MAC are out.
    static func candidates(mac: String, leases: [DHCPLease], hints: [String], subnets: [HostSubnet], now: Date) -> [IPv4] {
        let live = leases.filter { $0.expiry > now }.sorted { $0.expiry > $1.expiry }
        let takenByOthers = Set(live.filter { $0.macAddress != nil && $0.macAddress != mac }.compactMap { IPv4($0.ipAddress) })
        let ours = live.filter { $0.macAddress == mac }.compactMap { IPv4($0.ipAddress) }
        let anonymous = live.filter { $0.macAddress == nil }.compactMap { IPv4($0.ipAddress) }
        var result: [IPv4] = []
        for address in ours + hints.compactMap(IPv4.init) + anonymous
        where !result.contains(address) && !takenByOthers.contains(address) && subnets.contains(where: { acceptable(address, in: $0) }) {
            result.append(address)
        }
        return Array(result.prefix(16))
    }

    /// A guest address: a host in the subnet, not the Mac's own address there.
    static func acceptable(_ address: IPv4, in subnet: HostSubnet) -> Bool {
        subnet.isHost(address) && address != subnet.hostAddress
    }

    static func sendProbe(to address: IPv4) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(9).bigEndian  // discard
        target.sin_addr.s_addr = address.value.bigEndian
        _ = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, nil, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}
