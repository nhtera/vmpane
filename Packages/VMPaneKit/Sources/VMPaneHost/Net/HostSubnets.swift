import Darwin
import Foundation

/// An IPv4 subnet on one of this Mac's interfaces: the host's own address there and its mask.
public struct HostSubnet: Sendable, Equatable {
    public let interface: String
    public let hostAddress: IPv4
    public let mask: UInt32

    public init(interface: String, hostAddress: IPv4, mask: UInt32) {
        self.interface = interface
        self.hostAddress = hostAddress
        self.mask = mask
    }

    public func contains(_ address: IPv4) -> Bool { address.value & mask == hostAddress.value & mask }

    /// The subnet's network and broadcast addresses are not hosts.
    public func isHost(_ address: IPv4) -> Bool {
        contains(address) && address.value & ~mask != 0 && address.value & ~mask != ~mask
    }

    /// VZ NAT's subnets: the host side of the `bridgeN` interfaces vmnet creates (192.168.64.1/24 by default).
    public static func natBridges() -> [HostSubnet] {
        all().filter { $0.interface.hasPrefix("bridge") }
    }

    /// Every IPv4 address on this Mac's interfaces.
    public static func all() -> [HostSubnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var subnets: [HostSubnet] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                let netmask = entry.pointee.ifa_netmask
            else { continue }
            let host = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            subnets.append(HostSubnet(interface: String(cString: entry.pointee.ifa_name), hostAddress: IPv4(value: host), mask: mask))
        }
        return subnets
    }
}
