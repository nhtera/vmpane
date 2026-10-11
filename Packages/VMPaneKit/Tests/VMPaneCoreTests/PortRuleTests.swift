import Testing

@testable import VMPaneCore

private func config(
    _ id: String = "web", _ proto: PortForwardConfig.Proto = .tcp, host: String = "127.0.0.1", port hostPort: Int = 8080,
    guest guestPort: Int = 80, origin: RuleOrigin = .user
) -> PortForwardConfig {
    PortForwardConfig(id: id, proto: proto, hostAddress: host, hostPort: hostPort, guestPort: guestPort, origin: origin)
}

@Test func validRulesCarryTheirParts() throws {
    let rule = try PortRule(config())
    #expect(rule.hostAddress == .loopback && rule.hostPort == 8080 && rule.guestPort == 80 && rule.proto == .tcp)
    #expect(try PortRule(config(host: "::1")).hostAddress == .loopbackV6)
    #expect(try PortRule(config(host: "0.0.0.0")).hostAddress == .allInterfaces)
}

/// A malformed rule cannot be constructed, so nothing downstream (HMP, listeners) ever sees one (Red Team #13).
@Test(arguments: [
    config(host: "localhost"), config(host: "192.168.1.5"), config(host: "1.2.3.4,hostfwd=tcp::1-:2"), config(host: " 127.0.0.1"),
    config(host: ""), config(port: 0), config(guest: 65536), config(port: -1), config("", .tcp), config("a b"), config("x;rm"),
    config(String(repeating: "a", count: 65)), config(host: "0.0.0.0", origin: .agent),
])
func malformedRulesAreRefused(_ bad: PortForwardConfig) {
    #expect(throws: PortRule.Invalid.self) { try PortRule(bad) }
}

@Test func listsRefuseDuplicateIdsAndClashingPorts() throws {
    func list(_ configs: PortForwardConfig...) -> [Extensible<PortForwardConfig>] { configs.map { Extensible($0) } }
    #expect(try PortRule.rules(list(config("a"), config("b", host: "::1"), config("c", .udp))).count == 3)
    #expect(try PortRule.rules(list(config("a", port: 8080), config("b", port: 8081))).count == 2)
    #expect(throws: PortRule.Invalid(id: "a", reason: "the id is used twice")) {
        try PortRule.rules(list(config("a", port: 8080), config("a", port: 9090)))
    }
    #expect(throws: PortRule.Invalid.self) { try PortRule.rules(list(config("a"), config("b"))) }
    #expect(throws: PortRule.Invalid.self) { try PortRule.rules(list(config("a"), config("b", host: "0.0.0.0"))) }
    #expect(try PortRule.rules(list(config("a", host: "::1"), config("b", host: "0.0.0.0"))).count == 2, "IPv4 any is not ::1")
}
