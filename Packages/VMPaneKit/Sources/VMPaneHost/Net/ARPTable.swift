import Darwin
import Foundation

/// This Mac's IPv4 neighbour (ARP) entries, as `arp -an` lists them, read from the routing table by sysctl.
/// A VZ NAT guest that has talked to its gateway (DHCP, DNS) has an entry on the NAT bridge.
public struct ARPEntry: Sendable, Equatable {
    public let ipAddress: IPv4
    /// `aa:bb:…`, two digits per octet.
    public let macAddress: String
    public let interface: String

    public static func read() -> [ARPEntry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4  // the table can grow between the two calls
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return parse(Array(buffer.prefix(size)))
    }

    /// Entries in a `NET_RT_FLAGS` dump: route messages, each a header, the destination address
    /// (`sockaddr_inarp`) and the link-layer address (`sockaddr_dl`). Incomplete entries have no MAC and are skipped.
    static func parse(_ bytes: [UInt8]) -> [ARPEntry] {
        var entries: [ARPEntry] = []
        let headerSize = MemoryLayout<rt_msghdr>.size
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset + headerSize <= raw.count {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let length = Int(header.rtm_msglen)
                guard length >= headerSize, offset + length <= raw.count else { break }
                defer { offset += length }
                let addresses = offset + headerSize
                guard header.rtm_addrs & RTA_DST != 0, header.rtm_addrs & RTA_GATEWAY != 0,
                    addresses + MemoryLayout<sockaddr_in>.size <= offset + length
                else { continue }
                let destination = raw.loadUnaligned(fromByteOffset: addresses, as: sockaddr_in.self)
                guard destination.sin_family == UInt8(AF_INET) else { continue }
                let link = addresses + roundUp(Int(destination.sin_len))
                guard link + 8 <= offset + length else { continue }
                // sockaddr_dl: len, family, index (2), type, nlen, alen, slen, then name + address bytes.
                let family = raw[link + 1]
                let index = UInt32(raw[link + 2]) | UInt32(raw[link + 3]) << 8
                let nameLength = Int(raw[link + 5])
                let addressLength = Int(raw[link + 6])
                let macStart = link + 8 + nameLength
                guard family == UInt8(AF_LINK), addressLength == 6, macStart + 6 <= offset + length else { continue }
                let mac = (0..<6).map { String(format: "%02x", raw[macStart + $0]) }.joined(separator: ":")
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                let interface = if_indextoname(index, &name) != nil ? String(cString: name) : ""
                entries.append(
                    ARPEntry(
                        ipAddress: IPv4(value: UInt32(bigEndian: destination.sin_addr.s_addr)), macAddress: mac, interface: interface))
            }
        }
        return entries
    }

    /// Socket addresses in route messages are padded to 4 bytes (an empty one still takes 4).
    private static func roundUp(_ length: Int) -> Int { length > 0 ? 1 + ((length - 1) | 3) : 4 }
}
