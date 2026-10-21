import Foundation
import VMPaneControl
import VMPaneCore

/// How the MCP tools reach VMs: the library (as a policy-bound agent: only VMs at `observe` or above are
/// visible) and each VM's helper (which enforces the VM's policy on every call and audits it). One session per
/// `vmpane mcp` process.
public actor VMAccess {
    let ops: LibraryOps
    var connector: HelperConnector
    /// The last screenshot's scale per VM: tools take coordinates in screenshot pixels.
    private var scales: [UUID: Double] = [:]
    private var sessions: [UUID: HelperDiscovery.Session] = [:]
    /// The ids vm_read_screen gave out, per VM, for vm_click and vm_move by `element`.
    private var elements: [UUID: ElementCache] = [:]

    public init(ops: LibraryOps, connector: HelperConnector) {
        self.ops = ops
        self.connector = connector
    }

    /// The MCP client's name, as it gave it: helpers record it (as claimed) and name its snapshots after it.
    public func setClient(_ name: String) {
        guard connector.clientName != name else { return }
        connector = connector.named(name)
        for session in sessions.values { session.client.close() }
        sessions = [:]  // later connections say the new name
    }

    public func list() throws -> [VMLibrary.Item] {
        do {
            return try ops.list()
        } catch let denied as LibraryOps.PolicyDenied {
            throw ToolFailure(denied.reason)
        }
    }

    func item(_ selector: String) throws -> VMLibrary.Item {
        do {
            return try VMSelector.resolve(selector, in: try list())
        } catch let failure as VMSelector.Failure {
            throw ToolFailure(failure.description)
        }
    }

    /// A control method on the VM's helper. `launching` starts the helper (headless) when it is not running.
    func call(
        _ selector: String, _ method: ControlMethod, _ params: JSONValue? = nil, launching: Bool = false, timeout: Duration = .seconds(60)
    )
        async throws -> JSONValue
    {
        let item = try item(selector)
        let session = try await session(item, launching: launching)
        do {
            return try await session.client.call(method.rawValue, params: params, timeout: timeout)
        } catch let error as RPCError {
            throw ToolFailure(Self.explain(error, vm: item.config?.name ?? selector), code: error.code, data: error.data)
        } catch let error as ControlClientError {
            throw ToolFailure(Self.explain(error, vm: item.config?.name ?? selector))
        }
    }

    /// Runs `body` on a connection of its own (for streams of notifications, like an exec's output).
    func withOwnConnection<T: Sendable>(_ selector: String, _ body: (UDSClient) async throws -> T) async throws -> T {
        let item = try item(selector)
        let session: HelperDiscovery.Session
        do {
            session = try await connector.connect(item.id)
        } catch HelperDiscovery.DiscoveryError.notRunning {
            throw ToolFailure("\(item.config?.name ?? selector) is not running (vm_power start)")
        }
        defer { session.client.close() }
        do {
            return try await body(session.client)
        } catch let error as RPCError {
            throw ToolFailure(Self.explain(error, vm: item.config?.name ?? selector))
        } catch let error as ControlClientError {
            throw ToolFailure(Self.explain(error, vm: item.config?.name ?? selector))
        }
    }

    private func session(_ item: VMLibrary.Item, launching: Bool) async throws -> HelperDiscovery.Session {
        if let cached = sessions[item.id], cached.client.isOpen { return cached }
        let session: HelperDiscovery.Session
        do {
            session = launching ? try await connector.connectLaunching(item) : try await connector.connect(item.id)
        } catch HelperDiscovery.DiscoveryError.notRunning {
            throw ToolFailure("\(item.config?.name ?? "the VM") is not running (vm_power start)")
        } catch let error as RPCError {
            throw ToolFailure(error.message)
        }
        sessions[item.id] = session
        return session
    }

    func setScale(_ scale: Double, for selector: String) throws {
        scales[try item(selector).id] = scale
    }

    func scale(for selector: String) throws -> Double { scales[try item(selector).id] ?? 1 }

    /// Whether a screenshot (or a screen read) has set the VM's scale yet.
    func hasScale(for selector: String) throws -> Bool { scales[try item(selector).id] != nil }

    /// Ids for `rects` (guest pixels) of a screen read.
    func remember(_ rects: [CGRect], prefix: String, for selector: String) throws -> [String] {
        try elements[item(selector).id, default: ElementCache()].add(rects, prefix: prefix)
    }

    /// An input changed the screen in `box` (guest pixels) by `ratio`: the ids there are stale.
    func screenChanged(_ box: CGRect?, ratio: Double, for selector: String) throws {
        try elements[item(selector).id]?.changed(box, ratio: ratio)
    }

    /// An element's box in guest pixels.
    func element(_ id: String, for selector: String) throws -> CGRect {
        try (elements[item(selector).id] ?? ElementCache()).rect(id).get()
    }

    /// What the model reads when a call is refused or fails.
    static func explain(_ error: RPCError, vm: String) -> String {
        switch ControlErrorCode(rawValue: error.code) {
        case .policyDenied? where error.message.hasSuffix("is not an allowed method"):
            // A helper started by an older VMPane does not know the method yet.
            "\(vm) runs an older VMPane helper that cannot do this yet: restart the VM (shut it down and start it again)."
        case .policyDenied?:
            "Refused by \(vm)'s agent access setting: \(error.message). Its owner can raise it in VMPane (Settings › AI agents)."
        case .agentUnavailable?:
            "\(error.message). Commands, files and the clipboard need VMPane's guest tools running in \(vm)."
        default:
            error.message
        }
    }

    /// A call the helper never answered, a result the model reads like a refusal. The kill switch closes agents'
    /// connections, which can reach a call before the helper's own answer does.
    static func explain(_ error: ControlClientError, vm: String) -> String {
        switch error {
        case .connectionClosed:
            "\(vm)'s helper closed the connection: the VM stopped or restarted, or VMPane's kill switch stopped AI agents."
        case .timedOut(let method):
            "\(vm) did not answer in time (\(method))."
        }
    }
}
