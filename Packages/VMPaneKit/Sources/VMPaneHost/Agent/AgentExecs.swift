import Foundation
import VMPaneControl
import VMPaneCore

/// Processes started through `agent.exec`: their output goes to the control connection that started them
/// (`exec.output`, then `exec.exited` once all output is delivered), and only that connection may feed their
/// stdin or signal them.
actor AgentExecs {
    private struct Route {
        let owner: ControlConnection
        let connection: AgentConnection
        let stdin: UInt32?
    }

    private enum Exit {
        case waiting(CheckedContinuation<AgentExecExited?, Never>)
        case arrived(AgentExecExited)
    }

    private var routes: [UInt32: Route] = [:]
    private var exits: [UInt32: Exit] = [:]

    static let streamNames = AgentConnection.StreamNames(
        inbound: { [$0["stdout"]?.intValue, $0["stderr"]?.intValue].compactMap { $0.map(UInt32.init) } },
        outbound: { [$0["stdin"]?.intValue].compactMap { $0.map(UInt32.init) } })

    /// Starts the process and its output forwarding; returns the exec id.
    func start(_ params: AgentExecStartParams, owner: ControlConnection, on connection: AgentConnection) async throws
        -> UInt32
    {
        let call = try await connection.call(AgentMethod.execStart, RPCParams.encode(params).get(), streams: Self.streamNames)
        let started = try RPCParams.decode(AgentExecStartResult.self, from: call.result).get()
        routes[started.execId] = Route(owner: owner, connection: connection, stdin: started.stdin)
        let outputs = [("stdout", call.inbound[started.stdout]), ("stderr", call.inbound[started.stderr])]
        Task {
            await withTaskGroup(of: Void.self) { group in
                for case (let name, let stream?) in outputs {
                    group.addTask { await Self.forward(stream, name: name, execId: started.execId, to: owner) }
                }
            }
            let exited = await self.waitForExit(started.execId)
            let params: JSONValue = [
                "execId": .int(Int64(started.execId)),
                "code": exited?.code.map { .int(Int64($0)) } ?? .null,
                "signal": exited.map { $0.signal.map(JSONValue.string) ?? .null } ?? "disconnected",
                "timedOut": .bool(exited?.timedOut ?? false),
            ]
            owner.send(.request(RPCRequest(id: nil, method: ControlNotification.execExited.rawValue, params: params)))
            self.remove(started.execId)
        }
        return started.execId
    }

    private static func forward(_ stream: AgentInbound, name: String, execId: UInt32, to owner: ControlConnection) async {
        while let data = try? await stream.next() {
            let params: JSONValue = [
                "execId": .int(Int64(execId)), "stream": .string(name), "dataB64": .string(data.base64EncodedString()),
            ]
            owner.send(.request(RPCRequest(id: nil, method: ControlNotification.execOutput.rawValue, params: params)))
        }
    }

    private func waitForExit(_ execId: UInt32) async -> AgentExecExited? {
        if case .arrived(let exited)? = exits.removeValue(forKey: execId) { return exited }
        guard routes[execId] != nil else { return nil }  // the agent went away before the process ended
        return await withCheckedContinuation { exits[execId] = .waiting($0) }
    }

    private func remove(_ execId: UInt32) {
        routes[execId] = nil
        exits[execId] = nil
    }

    /// `exec.exited` from the agent. It can come before `start` has recorded the route (a quick process), so
    /// it is kept until asked for; a guest cannot grow the table past a small bound.
    func exited(_ notice: AgentExecExited) {
        if case .waiting(let continuation)? = exits.removeValue(forKey: notice.execId) {
            continuation.resume(returning: notice)
        } else if exits.count < 1024 {
            exits[notice.execId] = .arrived(notice)
        }
    }

    /// The agent connection closed: every running exec ends without an exit status.
    func disconnected(_ connection: AgentConnection) {
        for (execId, route) in routes where route.connection === connection {
            routes[execId] = nil
            if case .waiting(let continuation)? = exits.removeValue(forKey: execId) { continuation.resume(returning: nil) }
        }
        // Unclaimed exits belong to the old connection; a new agent numbers its execs from 1 again.
        exits = exits.filter {
            if case .waiting = $0.value { return true }
            return false
        }
    }

    private func route(_ execId: UInt32, owner: ControlConnection) throws -> Route {
        guard let route = routes[execId], route.owner === owner else {
            throw RPCError(.invalidParams, "no running exec \(execId) started by this connection")
        }
        return route
    }

    func input(_ execId: UInt32, data: Data, eof: Bool, owner: ControlConnection) async throws {
        let route = try route(execId, owner: owner)
        guard let stdin = route.stdin else { throw RPCError(.invalidParams, "exec \(execId) has no stdin (start it with stdin: true)") }
        if !data.isEmpty { try await route.connection.send(data, on: stdin) }
        if eof { try await route.connection.end(stdin) }
    }

    func signal(_ execId: UInt32, signal: AgentSignal, owner: ControlConnection) async throws {
        let route = try route(execId, owner: owner)
        _ = try await route.connection.call(
            AgentMethod.execSignal, RPCParams.encode(AgentExecSignalParams(execId: execId, signal: signal)).get())
    }
}
