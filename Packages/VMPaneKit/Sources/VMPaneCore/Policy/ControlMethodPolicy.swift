import Foundation

/// Who is calling, for policy decisions.
public enum ClientIdentity: Sendable, Equatable {
    /// The VMPane app: exempt from levels.
    case ui
    /// An interactive human CLI session holding the one-time UI grant: decided at `admin`, never `uiOnly`.
    case `operator`
    /// Non-interactive CLI or MCP: decided at the VM's MCP policy level, never exempt.
    case automated
}

/// Minimum requirement of one control method.
public enum PolicyRule: Sendable, Equatable {
    /// Every caller, even at level `off`.
    case any
    /// The app only.
    case uiOnly
    case level(PolicyLevel)
    /// `control`, and for automated callers also `clipboard.allowWithAgents`.
    case clipboard
    /// `exec` for `as: "user"` (the default), `admin` for `as: "admin"`; any other value is denied.
    case agentExec
    /// `admin`; a patch touching `PolicyEnforcer.uiOnlySettings`, or adding or changing a port rule not bound
    /// to loopback, is `uiOnly`.
    case settingsApply

    /// The "min level" cell of `docs/control-protocol.md`.
    public var summary: String {
        switch self {
        case .any: "any"
        case .uiOnly: "uiOnly"
        case .level(let level): level.rawValue
        case .clipboard: "control + clipboard.allowWithAgents"
        case .agentExec: "exec (as:user), admin (as:admin)"
        case .settingsApply: "admin; sensitive patch: uiOnly"
        }
    }
}

/// The method → policy table: the one place access levels are defined. Unlisted methods are denied.
public enum ControlMethodPolicy {
    public static let table: [String: PolicyRule] = [
        "helper.hello": .any,
        "helper.shutdown": .level(.admin),
        "vm.info": .level(.observe),
        "vm.start": .level(.control),
        "vm.pause": .level(.control),
        "vm.resume": .level(.control),
        "vm.suspend": .level(.control),
        "vm.stop": .level(.admin),
        "vm.snapshot.list": .level(.observe),
        "vm.snapshot.create": .level(.control),
        "vm.snapshot.restore": .level(.control),
        "vm.snapshot.delete": .level(.admin),
        "vm.screenshot": .level(.observe),
        "vm.input.key": .level(.control),
        "vm.input.text": .level(.control),
        "vm.input.pointer": .level(.control),
        "vm.input.scroll": .level(.control),
        "vm.display.show": .level(.control),
        "vm.install.cancel": .uiOnly,
        "vm.settings.get": .level(.observe),
        "vm.settings.apply": .settingsApply,
        "vm.ports.list": .level(.observe),
        "vm.clipboard.read": .clipboard,
        "vm.clipboard.write": .clipboard,
        "agent.status": .level(.observe),
        "agent.exec": .agentExec,
        "agent.exec.input": .level(.exec),
        "agent.exec.signal": .level(.exec),
        "agent.file.push": .level(.exec),
        "agent.file.pull": .level(.exec),
        "vm.files.drop": .level(.exec),
        "vm.files.cancel": .level(.exec),
        "mcp.enableAll": .uiOnly,
        "mcp.disableAll": .any,
        "events.subscribe": .level(.observe),
        "library.list": .any,
        "vm.create": .uiOnly,
        "vm.clone": .uiOnly,
        "vm.delete": .uiOnly,
        "vm.import": .uiOnly,
    ]
}

/// Facts about the VM that some rules need.
public struct PolicyContext: Sendable, Equatable {
    public var clipboardAllowWithAgents: Bool
    /// The VM's port rules that listen beyond loopback (the user's): a patch that keeps them unchanged is not
    /// opening anything.
    public var exposedPortRules: [PortForwardConfig]

    public init(clipboardAllowWithAgents: Bool, exposedPortRules: [PortForwardConfig] = []) {
        self.clipboardAllowWithAgents = clipboardAllowWithAgents
        self.exposedPortRules = exposedPortRules
    }
}

public enum PolicyDecision: Sendable, Equatable {
    case allow
    case deny(String)
}

/// The one gate for helper requests and Core-direct library operations.
public enum PolicyEnforcer {
    /// Settings that only the app may change.
    /// `removable` and `network` reach the host's files and LAN; `name` is what the person sees in a question.
    public static let uiOnlySettings: Set<String> = ["mcp", "clipboard", "shares", "agent", "windows", "removable", "network", "name"]

    public static func decide(
        method: String, params: JSONValue?, level: PolicyLevel, identity: ClientIdentity,
        context: PolicyContext
    ) -> PolicyDecision {
        guard let rule = ControlMethodPolicy.table[method] else {
            return identity == .ui ? .allow : .deny("\(method) is not an allowed method")
        }
        switch requirement(rule, params: params, context: context, identity: identity) {
        case .failure(let denial):
            return .deny(denial.reason)
        case .success(.any):
            return .allow
        case .success(.uiOnly):
            return identity == .ui ? .allow : .deny("\(method) is only available in the VMPane app")
        case .success(.level(let required)):
            switch identity {
            case .ui, .operator: return .allow  // operator is decided at admin, the highest level
            case .automated:
                return level != .off && level >= required
                    ? .allow : .deny("\(method) needs policy level \(required.rawValue); this VM allows \(level.rawValue)")
            }
        case .success:
            return .deny("\(method): unresolved rule")
        }
    }

    /// Resolves discriminated rules to `any`, `uiOnly` or a level.
    private static func requirement(
        _ rule: PolicyRule, params: JSONValue?, context: PolicyContext,
        identity: ClientIdentity
    ) -> Result<PolicyRule, Denial> {
        switch rule {
        case .any, .uiOnly, .level:
            return .success(rule)
        case .clipboard:
            if identity == .automated && !context.clipboardAllowWithAgents {
                return .failure(Denial("clipboard access for agents is off for this VM"))
            }
            return .success(.level(.control))
        case .agentExec:
            switch params?["as"] {
            case nil, "user": return .success(.level(.exec))
            case "admin": return .success(.level(.admin))
            default: return .failure(Denial("agent.exec: as must be \"user\" or \"admin\""))
            }
        case .settingsApply:
            guard let patch = params?["patch"]?.objectValue else { return .failure(Denial("vm.settings.apply: patch must be an object")) }
            if !uiOnlySettings.isDisjoint(with: patch.keys)
                || opensPortBeyondLoopback(patch["portForwards"], kept: context.exposedPortRules)
            {
                return .success(.uiOnly)
            }
            return .success(.level(.admin))
        }
    }

    private struct Denial: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// Host addresses an agent may bind port rules to. Anything else (all interfaces in any spelling, a
    /// LAN address, a missing address) exposes the guest beyond this Mac and is uiOnly.
    public static let loopbackAddresses: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// Whether `rules` (the patch's whole list) adds or changes one that listens beyond loopback; the user's
    /// own such rules, kept as they are, do not count.
    private static func opensPortBeyondLoopback(_ rules: JSONValue?, kept: [PortForwardConfig]) -> Bool {
        guard let rules else { return false }
        guard case .array(let items) = rules else { return true }
        return items.contains { item in
            if loopbackAddresses.contains(item["hostAddress"]?.stringValue ?? "") { return false }
            return !kept.contains {
                item["id"]?.stringValue == $0.id && item["proto"]?.stringValue == $0.proto.rawValue
                    && item["hostAddress"]?.stringValue == $0.hostAddress && item["hostPort"]?.intValue == Int64($0.hostPort)
                    && item["guestPort"]?.intValue == Int64($0.guestPort)
            }
        }
    }
}
