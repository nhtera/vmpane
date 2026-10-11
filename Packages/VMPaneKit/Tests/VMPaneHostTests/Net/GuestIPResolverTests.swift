import Foundation
import Synchronization
import Testing

@testable import VMPaneHost

private let ours = "52:54:00:aa:bb:01"
private let other = "52:54:00:aa:bb:02"
private let nat = HostSubnet(interface: "bridge100", hostAddress: IPv4(192, 168, 64, 1), mask: 0xffff_ff00)
private let later = Date().addingTimeInterval(3600)

private func ip(_ text: String) -> IPv4 { IPv4(text) ?? IPv4(value: 0) }
private func lease(_ address: String, _ mac: String?, expiry: Date = later) -> DHCPLease {
    let hardware = mac.map { "1,\($0)" } ?? "ff,1:2:3"
    let expires = String(Int(expiry.timeIntervalSince1970), radix: 16)
    return DHCPLease.parse("{\nip_address=\(address)\nhw_address=\(hardware)\nlease=0x\(expires)\n}")[0]
}

private final class Probes: Sendable {
    let list = Mutex<[IPv4]>([])
    var addresses: [IPv4] { list.withLock { $0 } }
}

/// A resolver over a scripted ARP table that learns `learns` once probed.
private func resolver(
    arp: [ARPEntry], leases: [DHCPLease] = [], learns: [ARPEntry] = [], probed: Probes = Probes()
) throws -> GuestIPResolver {
    var resolver = try #require(GuestIPResolver(macAddress: ours))
    let table = Mutex(arp)
    resolver.neighbours = { table.withLock { $0 } }
    resolver.leases = { leases }
    resolver.subnets = { [nat] }
    resolver.settle = .milliseconds(1)
    resolver.probe = { address in
        probed.list.withLock { $0.append(address) }
        table.withLock { $0 += learns.filter { $0.ipAddress == address } }
    }
    return resolver
}

@Test func anARPEntryForTheVMsMACIsTheAnswer() async throws {
    let found = try await resolver(arp: [ARPEntry(ipAddress: ip("192.168.64.7"), macAddress: ours, interface: "bridge100")]).resolve()
    #expect(found == ip("192.168.64.7"))
}

@Test func agentHintsAreProbedAndVerifiedByMAC() async throws {
    let probed = Probes()
    let learns = [ARPEntry(ipAddress: ip("192.168.64.9"), macAddress: ours, interface: "bridge100")]
    let found = try await resolver(arp: [], learns: learns, probed: probed).resolve(hints: ["192.168.64.9"])
    #expect(found == ip("192.168.64.9"))
    #expect(probed.addresses == [ip("192.168.64.9")])
}

/// A guest cannot point forwards at the host, another VM, loopback or the LAN (Red Team #13).
@Test func hostileHintsAreNeverUsed() async throws {
    let probed = Probes()
    let learns = [
        ARPEntry(ipAddress: ip("192.168.64.20"), macAddress: other, interface: "bridge100"),  // another VM's address
        ARPEntry(ipAddress: ip("10.0.0.5"), macAddress: ours, interface: "en0"),  // the LAN, even with our MAC
    ]
    let hints = ["127.0.0.1", "169.254.1.1", "192.168.64.1", "192.168.64.255", "192.168.64.0", "10.0.0.5", "192.168.64.20", "x"]
    let found = try await resolver(arp: [], leases: [lease("192.168.64.21", other)], learns: learns, probed: probed).resolve(hints: hints)
    #expect(found == nil)
    #expect(probed.addresses == [ip("192.168.64.20")], "only in-subnet guest addresses are probed")
    let taken = GuestIPResolver.candidates(
        mac: ours, leases: [lease("192.168.64.21", other)], hints: ["192.168.64.21"], subnets: [nat], now: Date())
    #expect(taken.isEmpty, "an address leased to another MAC is not a candidate")
}

@Test func leasesNominateInOrderAndExpiredOnesDoNot() {
    let leases = [
        lease("192.168.64.30", nil), lease("192.168.64.31", ours), lease("192.168.64.32", ours, expiry: Date().addingTimeInterval(-60)),
    ]
    let candidates = GuestIPResolver.candidates(mac: ours, leases: leases, hints: ["192.168.64.40"], subnets: [nat], now: Date())
    #expect(candidates == [ip("192.168.64.31"), ip("192.168.64.40"), ip("192.168.64.30")])
}

@Test func noNATBridgeMeansNoAnswer() async throws {
    var resolver = try resolver(arp: [ARPEntry(ipAddress: ip("192.168.64.7"), macAddress: ours, interface: "bridge100")])
    resolver.subnets = { [] }
    #expect(await resolver.resolve() == nil)
    #expect(GuestIPResolver(macAddress: "not a mac") == nil)
}
