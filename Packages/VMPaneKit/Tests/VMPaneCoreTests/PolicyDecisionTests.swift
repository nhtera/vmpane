import Foundation
import Testing

@testable import VMPaneCore

private let identities: [ClientIdentity] = [.ui, .operator, .automated]
private let agentsAllowed = PolicyContext(clipboardAllowWithAgents: true)
private let agentsBlocked = PolicyContext(clipboardAllowWithAgents: false)

/// Expected decision for a plain rule, written independently of the enforcer.
private func expected(_ rule: PolicyRule, level: PolicyLevel, identity: ClientIdentity) -> Bool {
    switch (rule, identity) {
    case (.any, _): true
    case (.uiOnly, .ui): true
    case (.uiOnly, _): false
    case (.level, .ui), (.level, .operator): true
    case (.level(let required), .automated): level != .off && level >= required
    default: false
    }
}

@Test(arguments: ControlMethodPolicy.table.keys.sorted())
func everyMethodTimesLevelTimesIdentity(method: String) throws {
    let rule = try #require(ControlMethodPolicy.table[method])
    for level in PolicyLevel.allCases {
        for identity in identities {
            let decision = PolicyEnforcer.decide(
                method: method, params: paramsFor(rule), level: level, identity: identity,
                context: agentsAllowed)
            let allowed = decision == .allow
            switch rule {
            case .any, .uiOnly, .level:
                #expect(allowed == expected(rule, level: level, identity: identity), "\(method) \(level) \(identity)")
            case .clipboard:
                #expect(allowed == expected(.level(.control), level: level, identity: identity), "\(method) \(level) \(identity)")
            case .agentExec:
                #expect(allowed == expected(.level(.exec), level: level, identity: identity), "\(method) \(level) \(identity)")
            case .settingsApply:
                #expect(allowed == expected(.level(.admin), level: level, identity: identity), "\(method) \(level) \(identity)")
            }
        }
    }
}

/// Minimal valid params for discriminated rules.
private func paramsFor(_ rule: PolicyRule) -> JSONValue? {
    switch rule {
    case .settingsApply: ["patch": ["cpu": ["count": 2]]]
    case .agentExec: ["argv": ["ls"]]
    default: nil
    }
}

@Test func unlistedMethodsAreDeniedExceptForTheApp() {
    for identity in [ClientIdentity.operator, .automated] {
        #expect(
            PolicyEnforcer.decide(method: "vm.format", params: nil, level: .admin, identity: identity, context: agentsAllowed) != .allow)
    }
    #expect(PolicyEnforcer.decide(method: "vm.format", params: nil, level: .off, identity: .ui, context: agentsAllowed) == .allow)
}

@Test func agentExecDiscriminator() {
    func decide(_ params: JSONValue, _ level: PolicyLevel) -> PolicyDecision {
        PolicyEnforcer.decide(method: "agent.exec", params: params, level: level, identity: .automated, context: agentsAllowed)
    }
    #expect(decide(["as": "user"], .exec) == .allow)
    #expect(decide(["as": "admin"], .exec) != .allow)
    #expect(decide(["as": "admin"], .admin) == .allow)
    #expect(decide(["as": "root"], .admin) != .allow)  // unknown discriminator value
    #expect(decide(["as": 1], .admin) != .allow)
}

@Test(arguments: ["mcp", "clipboard", "shares", "agent", "windows"])
func sensitiveSettingsAreAppOnly(key: String) {
    let params: JSONValue = ["patch": .object([key: ["x": 1]])]
    #expect(
        PolicyEnforcer.decide(method: "vm.settings.apply", params: params, level: .admin, identity: .automated, context: agentsAllowed)
            != .allow)
    #expect(
        PolicyEnforcer.decide(method: "vm.settings.apply", params: params, level: .admin, identity: .operator, context: agentsAllowed)
            != .allow)
    #expect(
        PolicyEnforcer.decide(method: "vm.settings.apply", params: params, level: .off, identity: .ui, context: agentsAllowed) == .allow)
}

@Test func portRulesOnAllInterfacesAreAppOnly() {
    func decide(_ address: String) -> PolicyDecision {
        let params: JSONValue = ["patch": ["portForwards": [["hostAddress": .string(address), "hostPort": 80, "guestPort": 80]]]]
        return PolicyEnforcer.decide(
            method: "vm.settings.apply", params: params, level: .admin, identity: .automated, context: agentsAllowed)
    }
    #expect(decide("127.0.0.1") == .allow)
    #expect(decide("::1") == .allow)
    for exposed in ["0.0.0.0", "::", "::0", "0", "[::]", "192.168.1.20", ""] {
        #expect(decide(exposed) != .allow, "\(exposed) must be app-only")
    }
    #expect(
        PolicyEnforcer.decide(
            method: "vm.settings.apply", params: ["patch": "x"], level: .admin, identity: .automated,
            context: agentsAllowed) != .allow)
}

@Test func clipboardNeedsTheAgentSwitchForAutomatedClients() {
    for method in ["vm.clipboard.read", "vm.clipboard.write"] {
        #expect(PolicyEnforcer.decide(method: method, params: nil, level: .admin, identity: .automated, context: agentsBlocked) != .allow)
        #expect(PolicyEnforcer.decide(method: method, params: nil, level: .control, identity: .automated, context: agentsAllowed) == .allow)
        #expect(PolicyEnforcer.decide(method: method, params: nil, level: .off, identity: .operator, context: agentsBlocked) == .allow)
    }
}

@Test func killSwitchStaysReachableAtOff() {
    #expect(
        PolicyEnforcer.decide(method: "mcp.disableAll", params: nil, level: .off, identity: .automated, context: agentsBlocked) == .allow)
    #expect(
        PolicyEnforcer.decide(method: "mcp.enableAll", params: nil, level: .admin, identity: .automated, context: agentsBlocked) != .allow)
}
