import Foundation
import VMPaneControl
import VMPaneCore
import os

/// Processes started through `agent.exec`: their output goes to the control connection that started them
/// (`exec.output`, then `exec.exited` once all output is delivered), and only that connection may feed their
/// stdin or signal them.
actor AgentExecs {
    private struct Route {
        /// Nil for the helper's own commands (`run`).
        let owner: ControlConnection?
        let connection: AgentConnection
        let stdin: UInt32?
    }

    private enum Exit {
        case waiting(CheckedContinuation<AgentExecExited?, Never>)
        case arrived(AgentExecExited)
    }

    /// An exec on one agent connection: a new agent numbers its execs from 1 again.
    private struct Key: Hashable {
        let connection: ObjectIdentifier
        let execId: UInt32

        init(_ connection: AgentConnection, _ execId: UInt32) {
            self.connection = ObjectIdentifier(connection)
            self.execId = execId
        }
    }

    private var routes: [Key: Route] = [:]
    private var exits: [Key: Exit] = [:]

    static let streamNames = AgentConnection.StreamNames(
        inbound: { [$0["stdout"]?.intValue, $0["stderr"]?.intValue].compactMap { $0.flatMap { UInt32(exactly: $0) } } },
        outbound: { [$0["stdin"]?.intValue].compactMap { $0.flatMap { UInt32(exactly: $0) } } })

    /// Starts the process and its output forwarding; returns the exec id.
    func start(_ params: AgentExecStartParams, owner: ControlConnection, on connection: AgentConnection) async throws
        -> UInt32
    {
        let call = try await connection.call(AgentMethod.execStart, RPCParams.encode(params).get(), streams: Self.streamNames)
        let started = try RPCParams.decode(AgentExecStartResult.self, from: call.result).get()
        let key = Key(connection, started.execId)
        routes[key] = Route(owner: owner, connection: connection, stdin: started.stdin)
        let outputs = [("stdout", call.inbound[started.stdout]), ("stderr", call.inbound[started.stderr])]
        Task {
            await withTaskGroup(of: Void.self) { group in
                for case (let name, let stream?) in outputs {
                    group.addTask { await Self.forward(stream, name: name, execId: started.execId, to: owner) }
                }
            }
            let exited = await self.waitForExit(key)
            let params: JSONValue = [
                "execId": .int(Int64(started.execId)),
                "code": exited?.code.map { .int(Int64($0)) } ?? .null,
                "signal": exited.map { $0.signal.map(JSONValue.string) ?? .null } ?? "disconnected",
                "timedOut": .bool(exited?.timedOut ?? false),
            ]
            await owner.sendWhenWritten(.request(RPCRequest(id: nil, method: ControlNotification.execExited.rawValue, params: params)))
            self.remove(key)
        }
        return started.execId
    }

    /// A command the helper ran for itself.
    struct Finished: Sendable {
        /// Nil when the agent went away first.
        let exited: AgentExecExited?
        let stdout: Data
        let stderr: Data
    }

    /// Runs a command for the helper itself: its output (up to 64 KiB per stream) and how it ended.
    func run(_ params: AgentExecStartParams, on connection: AgentConnection) async throws -> Finished {
        let call = try await connection.call(AgentMethod.execStart, RPCParams.encode(params).get(), streams: Self.streamNames)
        let started = try RPCParams.decode(AgentExecStartResult.self, from: call.result).get()
        let key = Key(connection, started.execId)
        routes[key] = Route(owner: nil, connection: connection, stdin: started.stdin)
        async let stdout = (try? await call.inbound[started.stdout]?.collect(limit: 65536)) ?? Data()
        async let stderr = (try? await call.inbound[started.stderr]?.collect(limit: 65536)) ?? Data()
        let output = await (stdout, stderr)
        let exited = await waitForExit(key)
        remove(key)
        return Finished(exited: exited, stdout: output.0, stderr: output.1)
    }

    private static func forward(_ stream: AgentInbound, name: String, execId: UInt32, to owner: ControlConnection) async {
        while let data = try? await stream.next() {
            let params: JSONValue = [
                "execId": .int(Int64(execId)), "stream": .string(name), "dataB64": .string(data.base64EncodedString()),
            ]
            // At the client's pace: a fast guest and a slow reader must not pile output up in the helper.
            await owner.sendWhenWritten(.request(RPCRequest(id: nil, method: ControlNotification.execOutput.rawValue, params: params)))
        }
    }

    private func waitForExit(_ key: Key) async -> AgentExecExited? {
        if case .arrived(let exited)? = exits.removeValue(forKey: key) { return exited }
        guard routes[key] != nil else { return nil }  // the agent went away before the process ended
        return await withCheckedContinuation { exits[key] = .waiting($0) }
    }

    private func remove(_ key: Key) {
        routes[key] = nil
        exits[key] = nil
    }

    /// Kills every process started through the connections in `owners` (the kill switch's agents).
    func kill(ownedBy owners: Set<ObjectIdentifier>) async {
        let doomed = routes.filter { _, route in route.owner.map { owners.contains(ObjectIdentifier($0)) } ?? false }
        AgentConnection.log.notice(
            "kill switch: \(doomed.count, privacy: .public) of \(self.routes.count, privacy: .public) exec(s) to kill")
        for (key, route) in doomed {
            let params = RPCParams.encode(AgentExecSignalParams(execId: key.execId, signal: .kill))
            do {
                _ = try await route.connection.call(AgentMethod.execSignal, try? params.get(), timeout: .seconds(2))
            } catch {
                AgentConnection.log.error(
                    "kill switch: exec \(key.execId, privacy: .public) not killed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `exec.exited` from the agent. It can come before `start` has recorded the route (a quick process), so
    /// it is kept until asked for; a guest cannot grow the table past a small bound.
    func exited(_ notice: AgentExecExited, on connection: AgentConnection) {
        let key = Key(connection, notice.execId)
        if case .waiting(let continuation)? = exits.removeValue(forKey: key) {
            continuation.resume(returning: notice)
        } else if exits.count < 1024 {
            exits[key] = .arrived(notice)
        }
    }

    /// The agent connection closed: every running exec ends without an exit status.
    func disconnected(_ connection: AgentConnection) {
        let gone = ObjectIdentifier(connection)
        for key in routes.keys where key.connection == gone {
            routes[key] = nil
            if case .waiting(let continuation)? = exits.removeValue(forKey: key) { continuation.resume(returning: nil) }
        }
        exits = exits.filter { $0.key.connection != gone }
    }

    private func route(_ execId: UInt32, owner: ControlConnection) throws -> Route {
        guard let route = routes.first(where: { $0.key.execId == execId && $0.value.owner === owner })?.value else {
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
