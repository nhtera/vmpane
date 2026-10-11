import Foundation

/// A port forward checked before it steers anything on the host (Red Team #13): a known host address, ports in
/// range, a plain id. Settings refuse rule lists that do not check out; backends build forwards only from these.
public struct PortRule: Sendable, Hashable {
    /// Where the host listens. All interfaces exposes the guest to the network, so only the user sets it (UI).
    public enum HostAddress: String, Sendable, CaseIterable {
        case loopback = "127.0.0.1"
        case loopbackV6 = "::1"
        case allInterfaces = "0.0.0.0"
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let id: String
        public let reason: String
        public var description: String { "port forward \(id): \(reason)" }
    }

    public let id: String
    public let proto: PortForwardConfig.Proto
    public let hostAddress: HostAddress
    public let hostPort: UInt16
    public let guestPort: UInt16
    public let origin: RuleOrigin

    public init(_ config: PortForwardConfig) throws(Invalid) {
        func invalid(_ reason: String) -> Invalid { Invalid(id: config.id, reason: reason) }
        let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...64).contains(config.id.count), config.id.unicodeScalars.allSatisfy(idCharacters.contains) else {
            throw invalid("the id must be 1–64 letters, digits, '.', '_' or '-'")
        }
        guard let address = HostAddress(rawValue: config.hostAddress) else {
            throw invalid("the host address must be 127.0.0.1, ::1 or 0.0.0.0")
        }
        guard let hostPort = UInt16(exactly: config.hostPort), hostPort > 0,
            let guestPort = UInt16(exactly: config.guestPort), guestPort > 0
        else { throw invalid("ports must be 1–65535") }
        guard !(address == .allInterfaces && config.origin == .agent) else {
            throw invalid("only the user can open a port on all interfaces")
        }
        id = config.id
        proto = config.proto
        hostAddress = address
        self.hostPort = hostPort
        self.guestPort = guestPort
        origin = config.origin
    }

    /// A VM's rules, each valid, with distinct ids and no two listening on the same host port (0.0.0.0 includes
    /// 127.0.0.1; ::1 is IPv6, a socket of its own).
    public static func rules(_ configs: [Extensible<PortForwardConfig>]) throws(Invalid) -> [PortRule] {
        var rules: [PortRule] = []
        for config in configs {
            let rule = try PortRule(config.fields)
            if rules.contains(where: { $0.id == rule.id }) { throw Invalid(id: rule.id, reason: "the id is used twice") }
            if let other = rules.first(where: { $0.listensWith(rule) }) {
                throw Invalid(id: rule.id, reason: "\(rule.proto.rawValue) port \(rule.hostPort) is already forwarded by \(other.id)")
            }
            rules.append(rule)
        }
        return rules
    }

    /// Both rules would listen on the same host socket.
    func listensWith(_ other: PortRule) -> Bool {
        guard proto == other.proto, hostPort == other.hostPort else { return false }
        let addresses: Set = [hostAddress, other.hostAddress]
        return addresses.count == 1 || addresses == [.loopback, .allInterfaces]
    }
}
