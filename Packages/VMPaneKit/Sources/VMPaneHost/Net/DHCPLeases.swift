import Foundation

/// macOS's DHCP server for VZ NAT (bootpd) records its leases in `/var/db/dhcpd_leases`:
///
///     {
///         name=ubuntu
///         ip_address=192.168.64.23
///         hw_address=1,52:54:0:97:60:1
///         identifier=1,52:54:0:97:60:1
///         lease=0x6acb49f0
///     }
///
/// `hw_address` is `1,<MAC>` when the guest's DHCP client identifies itself by MAC; guests that send a DUID
/// (systemd-networkd, e.g. Ubuntu cloud images) are recorded as `ff,<IAID+DUID>`, with no MAC to match.
public struct DHCPLease: Sendable, Equatable {
    public let ipAddress: String
    /// The client's MAC (`aa:bb:…`, two digits per octet), when the lease records one.
    public let macAddress: String?
    /// When the lease expires.
    public let expiry: Date

    public static let defaultFile = URL(fileURLWithPath: "/var/db/dhcpd_leases")

    /// The leases in `text`; malformed entries are skipped.
    public static func parse(_ text: String) -> [DHCPLease] {
        var leases: [DHCPLease] = []
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            switch line {
            case "{": fields = [:]
            case "}":
                if let lease = DHCPLease(fields) { leases.append(lease) }
                fields = [:]
            default:
                guard let equals = line.firstIndex(of: "=") else { continue }
                fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return leases
    }

    /// The leases on this Mac (none when the file cannot be read).
    public static func read(_ file: URL = defaultFile) -> [DHCPLease] {
        (try? String(contentsOf: file, encoding: .utf8)).map(parse) ?? []
    }

    private init?(_ fields: [String: String]) {
        guard let address = fields["ip_address"], IPv4(address) != nil,
            let hex = fields["lease"], hex.hasPrefix("0x"), let seconds = UInt64(hex.dropFirst(2), radix: 16)
        else { return nil }
        ipAddress = address
        expiry = Date(timeIntervalSince1970: TimeInterval(seconds))
        if let hardware = fields["hw_address"], hardware.hasPrefix("1,") {
            macAddress = Self.canonicalMAC(String(hardware.dropFirst(2)))
        } else {
            macAddress = nil
        }
    }

    /// `52:54:0:97:60:1` → `52:54:00:97:60:01`; nil unless six hex octets.
    public static func canonicalMAC(_ text: String) -> String? {
        let octets = text.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }
        var parts: [String] = []
        for octet in octets {
            guard (1...2).contains(octet.count), octet.allSatisfy(\.isHexDigit), let value = UInt8(octet, radix: 16) else { return nil }
            parts.append(String(format: "%02x", value))
        }
        return parts.joined(separator: ":")
    }
}

/// A dotted-quad IPv4 address, parsed strictly (no shorthand forms such as `10.1`).
public struct IPv4: Sendable, Hashable, CustomStringConvertible {
    public let value: UInt32

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        self.value = value
    }

    public init(value: UInt32) { self.value = value }

    public init(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) {
        value = UInt32(first) << 24 | UInt32(second) << 16 | UInt32(third) << 8 | UInt32(fourth)
    }

    public var description: String { (0..<4).map { String(value >> (24 - 8 * $0) & 0xff) }.joined(separator: ".") }
}
