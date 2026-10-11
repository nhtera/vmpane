import Foundation
import Testing

@testable import VMPaneHost

@Test func subnetsKnowTheirHosts() throws {
    let nat = HostSubnet(interface: "bridge100", hostAddress: try #require(IPv4("192.168.64.1")), mask: 0xffff_ff00)
    #expect(nat.isHost(try #require(IPv4("192.168.64.23"))))
    let network = try #require(IPv4("192.168.64.0"))
    let broadcast = try #require(IPv4("192.168.64.255"))
    #expect(!nat.isHost(network) && !nat.isHost(broadcast))
    #expect(!nat.contains(try #require(IPv4("192.168.65.2"))))
    #expect(HostSubnet.all().contains { $0.interface == "lo0" && $0.hostAddress.description == "127.0.0.1" })
}

/// The live table parses: the same entries `arp -an` shows (the gateway of the current network at least, when
/// this Mac is on one).
@Test func arpTableMatchesTheArpTool() throws {
    let entries = ARPEntry.read()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    process.arguments = ["-an"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    // "? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"; arp prints octets without padding.
    let listed = output.split(separator: "\n").compactMap { line -> String? in
        let parts = line.split(separator: " ")
        guard parts.count >= 6, parts[3] != "(incomplete)", let mac = DHCPLease.canonicalMAC(String(parts[3])) else { return nil }
        return "\(parts[1].dropFirst().dropLast()) \(mac) \(parts[5])"
    }
    let parsed = entries.map { "\($0.ipAddress) \($0.macAddress) \($0.interface)" }
    #expect(Set(listed).isSubset(of: Set(parsed)), "missing: \(Set(listed).subtracting(parsed))")
}
