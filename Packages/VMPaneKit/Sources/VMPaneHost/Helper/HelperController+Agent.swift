import CryptoKit
import Foundation
import VMPaneControl
import VMPaneCore

/// The guest agent in the helper: where its connections come from (VZ vsock, QEMU's `agent.sock`), what
/// happens when one arrives (clock sync, `agent.connectionChanged`) and the `agent.*` control methods.
extension HelperController {
    /// How long a request waits for an agent that is not connected yet (e.g. right after boot).
    static let agentWait: Duration = .seconds(5)

    /// Runs for the helper's lifetime: VZ vsock connections and connection changes.
    func startAgentPump() {
        guard agentTasks.isEmpty, let backend else { return }
        let hub = agentHub
        let sockets = backend.agentSockets
        agentTasks.append(
            Task {
                for await fd in sockets {
                    Task { await hub.serve(fd: fd, helloTimeout: .seconds(10)) }
                }
            })
        let events = hub.events
        agentTasks.append(
            Task { [weak self] in
                for await event in events { await self?.agentEvent(event) }
            })
    }

    private func agentEvent(_ event: AgentHub.Event) {
        switch event {
        case .connected(let connection, let peer):
            Self.log.notice("guest agent \(peer.hello.agentVersion, privacy: .public) connected (\(peer.hello.os, privacy: .public))")
            let execs = agentExecs
            let clipboard = clipboardAttach(connection, peer: peer)
            Task {
                for await notice in connection.notifications {
                    switch notice.method {
                    case AgentMethod.execExited:
                        if case .success(let exited) = RPCParams.decode(AgentExecExited.self, from: notice.params) {
                            await execs.exited(exited, on: connection)
                        }
                    case AgentMethod.clipboardChanged:
                        // Not awaited: a fetch's guest commands (a folder's listing) end with notices from this loop.
                        Task { await clipboard?.guestChanged() }
                    default:
                        break
                    }
                }
                await execs.disconnected(connection)
            }
            Task { await Self.syncClock(connection, peer: peer) }
            Task { await self.cloudInitReady() }
            Task { await self.mountShares(connection, peer: peer) }
            Task { await self.updateToolsIfOlder(connection, peer: peer) }
            mapSharesDrive(connection, peer: peer)
            broadcastAgent(connected: true)
        case .disconnected:
            let bridge = clipboardBridge
            Task { await bridge?.attach(nil) }
            broadcastAgent(connected: false)
        }
    }

    private func broadcastAgent(connected: Bool) {
        server?.broadcast(
            topic: "agent", method: ControlNotification.agentConnectionChanged.rawValue, params: ["connected": .bool(connected)])
    }

    /// Follows the VM state: QEMU's agent socket is connected while the VM runs (and no Windows install uses
    /// the port), and the agent connection ends when the VM stops.
    func agentFollowState(from previous: VMRunState, to next: VMRunState) {
        switch next {
        case .running:
            if previous != .paused { cloudInitStarted() }
            if config.backend == .qemu, windowsInstall?.isFinished ?? true, agentLink == nil {
                let link = UDSAgentLink(
                    socket: prepared.runFiles.childDirectory.appendingPathComponent("agent.sock"), hub: agentHub,
                    hostVersion: VMPane.version)
                agentLink = link
                Task { await link.start() }
            }
            if previous == .paused {
                let hub = agentHub
                Task {
                    await hub.setGuestPaused(false)
                    let status = await hub.status
                    if let connection = await hub.connection, let peer = status.peer { await Self.syncClock(connection, peer: peer) }
                }
            }
        case .paused:
            let hub = agentHub
            Task { await hub.setGuestPaused(true) }
        case .stopped, .error:
            let (link, hub) = (agentLink, agentHub)
            agentLink = nil
            Task {
                await link?.stop()
                await hub.disconnect("the VM stopped")
            }
        default:
            break
        }
    }

    // MARK: - Control methods

    func agentRequest(_ method: String, _ params: JSONValue?, from owner: ControlConnection) async -> Result<JSONValue, RPCError> {
        if ControlMethod(rawValue: method) == .agentStatus { return await agentStatus() }
        let stopped = agentStop(owner)
        let admitted = agentGeneration
        // While the guest tools update, their agent is back within a minute or two.
        let wait = toolsUpdate.installing ? toolsUpdate.reconnect : Self.agentWait
        guard let connection = await agentHub.waitForConnection(timeout: wait) else {
            return .failure(RPCError(.agentUnavailable, "the guest agent is not connected"))
        }
        // Agents may have been stopped, or the person may have taken over, while the guest's tools connected.
        if let refusal = agentStopRefusal(since: admitted, identity(of: owner), method: method) { return .failure(refusal) }
        do {
            switch ControlMethod(rawValue: method) {
            case .agentExec?:
                let request = try RPCParams.decode(ExecRequest.self, from: params).get()
                return .success(try await exec(request, owner: owner, on: connection, stopped: stopped))
            case .agentExecInput?:
                let input = try RPCParams.decode(ExecInput.self, from: params).get()
                guard let data = Data(base64Encoded: input.dataB64 ?? "") else { throw RPCError(.invalidParams, "dataB64 is not base64") }
                try await agentExecs.input(input.execId, data: data, eof: input.eof ?? false, owner: owner)
                return .success([:])
            case .agentExecSignal?:
                let signal = try RPCParams.decode(ExecSignal.self, from: params).get()
                try await agentExecs.signal(signal.execId, signal: signal.signal, owner: owner)
                return .success([:])
            case .agentFilePush?:
                let files = try RPCParams.decode(FileTransfer.self, from: params).get()
                return .success(["bytes": .int(Int64(try await Self.push(files, on: connection, stop: agentStop(owner))))])
            default:
                let files = try RPCParams.decode(FileTransfer.self, from: params).get()
                return .success(["bytes": .int(Int64(try await Self.pull(files, on: connection, stop: agentStop(owner))))])
            }
        } catch let error as RPCError {
            return .failure(error)
        } catch let error as AgentConnection.ConnectionError {
            if case .rpc(let agentError) = error { return .failure(agentError) }
            return .failure(RPCError(.agentUnavailable, error.description))
        } catch {
            return .failure(RPCError(.internalError, ErrorText.readable(error)))
        }
    }

    /// `agent.exec`: a command with its output to the caller, or (`desktop`) an app on the user's desktop.
    private func exec(
        _ request: ExecRequest, owner: ControlConnection, on connection: AgentConnection, stopped: (@Sendable () async -> Bool)?
    ) async throws -> JSONValue {
        if let input = request.input, input.utf8.count > Self.execInputLimit {
            throw RPCError(.invalidParams, "input is at most 64 KiB (feed more with agent.exec.input)")
        }
        let byAgent = identity(of: owner).identity == .automated
        if request.desktop == true {
            return try await openOnDesktop(request, owner: owner, byAgent: byAgent, on: connection, stopped: stopped)
        }
        let execId = try await agentExecs.start(request.agentParams, owner: owner, byAgent: byAgent, on: connection)
        // The kill switch only finds the execs already started: one that was starting (the guest slow to
        // answer, e.g. busy with a transfer) is ended here.
        if let stopped, await stopped() {
            try? await agentExecs.signal(execId, signal: .kill, owner: owner)
            throw inputStopError
        }
        // Input given with the command (shown in the confirmation, recorded as a hash): fed, then closed.
        if let input = request.input {
            try await agentExecs.input(execId, data: Data(input.utf8), eof: true, owner: owner)
        }
        return ["execId": .int(Int64(execId))]
    }

    /// `agent.exec {desktop: true}`: the program opens on the signed-in user's desktop and the call returns at once.
    private func openOnDesktop(
        _ request: ExecRequest, owner: ControlConnection, byAgent: Bool, on connection: AgentConnection,
        stopped: (@Sendable () async -> Bool)?
    ) async throws -> JSONValue {
        guard await agentHub.status.peer?.hello.caps?.contains(AgentCap.desktop) == true else {
            throw RPCError(.agentUnavailable, "Update the guest tools to open apps on the desktop")
        }
        guard request.runAs ?? .user == .user, request.stdin != true, request.input == nil, request.timeoutMs == nil else {
            throw RPCError(.invalidParams, "an app on the desktop runs as the user, without stdin or a timeout")
        }
        let started = try await agentExecs.launch(request.agentParams, owner: owner, byAgent: byAgent, on: connection)
        if let stopped, await stopped() {
            try? await agentExecs.signal(started.execId, signal: .kill, owner: owner)
            throw inputStopError
        }
        return ["execId": .int(Int64(started.execId)), "pid": .int(Int64(started.pid)), "launched": true]
    }

    /// From `hello`, with what changes over a connection (a user-session helper coming and going) asked live.
    private func agentStatus() async -> Result<JSONValue, RPCError> {
        let status = await agentHub.status
        guard let peer = status.peer else { return .success(["connected": false]) }
        var caps = peer.hello.caps ?? []
        var session = peer.hello.session ?? false
        if let connection = await agentHub.connection,
            let reply = try? await connection.call(AgentMethod.agentInfo, timeout: .seconds(5)),
            case .success(let info) = RPCParams.decode(AgentInfo.self, from: reply.result)
        {
            caps = info.caps ?? caps
            session = info.session ?? session
        }
        return .success([
            "connected": true, "version": .string(peer.hello.agentVersion), "os": .string(peer.hello.os),
            "osVersion": .string(peer.hello.osVersion ?? ""), "proto": .int(Int64(peer.proto)),
            "caps": .array(caps.map(JSONValue.string)), "session": .bool(session), "outdated": .bool(peer.toolsOutdated),
        ])
    }

    // MARK: - Files

    private static let fileChunk = 1 << 20
    static let execInputLimit = 64 << 10

    /// Host file → guest: hashed first (the agent checks size and SHA-256 before renaming into place).
    /// Pushes a host file to the guest; `progress` hears the bytes sent so far.
    static func push(
        _ files: FileTransfer, on connection: AgentConnection, progress: (@Sendable (UInt64) -> Void)? = nil,
        stop: (@Sendable () async -> Bool)? = nil
    ) async throws -> UInt64 {
        let url = URL(fileURLWithPath: files.hostPath)
        guard url.path.hasPrefix("/") else { throw RPCError(.invalidParams, "hostPath must be absolute") }
        let (size, sha256) = try await Blocking.run { () throws -> (UInt64, String) in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var size: UInt64 = 0
            while let data = try handle.read(upToCount: fileChunk), !data.isEmpty {
                hasher.update(data: data)
                size += UInt64(data.count)
            }
            return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
        let stream = try await connection.openOutbound()
        let params = AgentFilePushParams(
            path: files.guestPath, size: size, sha256: sha256, stream: stream, overwrite: files.overwrite ?? false)
        let call = try await connection.start(AgentMethod.filePush, RPCParams.encode(params).get())
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sent: UInt64 = 0
        while sent < size, !Task.isCancelled, await !connection.isAnswered(call) {
            if let stop, await stop() { break }  // the kill switch: the stream ends as failed
            let data = try await Blocking.run { try handle.read(upToCount: fileChunk) ?? Data() }
            guard !data.isEmpty else { break }
            try await connection.send(data, on: stream)
            sent += UInt64(data.count)
            progress?(sent)
        }
        try await connection.end(stream, status: sent == size ? .ok : .error)
        let result = try await connection.response(call, timeout: transferTimeout(size))
        return try RPCParams.decode(AgentFilePushResult.self, from: result.result).get().size
    }

    /// Guest file → host: written to a new private file beside the target (never through a symlink), synced and
    /// renamed once exactly the announced size arrived. An existing target is replaced only with `overwrite`.
    private static func pull(_ files: FileTransfer, on connection: AgentConnection, stop: (@Sendable () async -> Bool)? = nil)
        async throws -> UInt64
    {
        let url = URL(fileURLWithPath: files.hostPath)
        guard url.path.hasPrefix("/") else { throw RPCError(.invalidParams, "hostPath must be absolute") }
        let overwrite = files.overwrite ?? false
        var info = stat()
        if !overwrite, lstat(url.path, &info) == 0 { throw RPCError(.invalidParams, "\(url.path) exists (pass overwrite: true)") }
        let names = AgentConnection.StreamNames(inbound: { [$0["stream"]?.intValue].compactMap { $0.flatMap { UInt32(exactly: $0) } } })
        let call = try await connection.call(
            AgentMethod.filePull, RPCParams.encode(AgentFilePullParams(path: files.guestPath, maxBytes: 1 << 40)).get(),
            timeout: .seconds(30), streams: names)
        let size = try RPCParams.decode(AgentFilePullResult.self, from: call.result).get().size
        guard let stream = call.inbound.values.first else { throw RPCError(.internalError, "no stream for the file") }
        let directory = url.deletingLastPathComponent()
        let available = (try? SpaceGuard.freeBytes(at: directory)) ?? 0
        guard available >= size + Self.pullReserve else {
            stream.discard()
            throw RPCError(.insufficientSpace, "the file needs \(size >> 20) MiB, \(available >> 20) MiB free on the host")
        }
        let partial = directory.appendingPathComponent(".\(url.lastPathComponent).vmpane-partial")
        let fd = try createExclusive(partial)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var received: UInt64 = 0
        do {
            while let data = try await stream.next() {
                received += UInt64(data.count)
                guard received <= size else { throw RPCError(.internalError, "the guest sent more than announced") }
                if let stop, await stop() {
                    throw RPCError(.policyDenied, "AI agents were stopped (the kill switch, or Stop in the VM's window)")
                }
                try handle.write(contentsOf: data)
            }
            guard received == size else { throw RPCError(.internalError, "the guest sent \(received) of \(size) bytes") }
            fchmod(fd, 0o644)
            try handle.synchronize()
            try handle.close()
            let moved = overwrite ? rename(partial.path, url.path) : renamex_np(partial.path, url.path, UInt32(RENAME_EXCL))
            guard moved == 0 else { throw POSIXError.current() }
        } catch {
            stream.discard()
            try? handle.close()
            unlink(partial.path)
            throw error
        }
        return size
    }

    /// Copies guest file `path` into `handle` (a file `sink` made), counting its size against the sink's budget.
    static func pull(_ path: String, into handle: FileHandle, sink: HostFileSink, on connection: AgentConnection) async throws {
        let names = AgentConnection.StreamNames(inbound: { [$0["stream"]?.intValue].compactMap { $0.flatMap { UInt32(exactly: $0) } } })
        let call = try await connection.call(
            AgentMethod.filePull, RPCParams.encode(AgentFilePullParams(path: path, maxBytes: UInt64(HostFileSink.defaultMaxBytes))).get(),
            timeout: .seconds(30), streams: names)
        let size = try RPCParams.decode(AgentFilePullResult.self, from: call.result).get().size
        guard let stream = call.inbound.values.first else { throw RPCError(.internalError, "no stream for the file") }
        do {
            let available = (try? SpaceGuard.freeBytes(at: sink.root)) ?? 0
            guard available >= size + Self.pullReserve else {
                throw RPCError(.insufficientSpace, "the file needs \(size >> 20) MiB, \(available >> 20) MiB free on the host")
            }
            try sink.reserve(bytes: Int64(size))
            var received: UInt64 = 0
            while let data = try await stream.next() {
                received += UInt64(data.count)
                guard received <= size else { throw RPCError(.internalError, "the guest sent more than announced") }
                try handle.write(contentsOf: data)
            }
            guard received == size else { throw RPCError(.internalError, "the guest sent \(received) of \(size) bytes") }
        } catch {
            stream.discard()
            throw error
        }
    }

    /// Free space a pull leaves on the host volume.
    private static let pullReserve: UInt64 = 256 << 20

    /// A new 0600 file, never through a symlink; a stale one from an interrupted pull is replaced.
    private static func createExclusive(_ url: URL) throws -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var fd = open(url.path, flags, 0o600)
        if fd < 0, errno == EEXIST {
            unlink(url.path)
            fd = open(url.path, flags, 0o600)
        }
        guard fd >= 0 else { throw RPCError(.invalidParams, "cannot create \(url.path): \(String(cString: strerror(errno)))") }
        return fd
    }

    /// 60 s plus 10 MB/s: generous for vsock (≥ 100 MB/s) and virtio-serial (≥ 30 MB/s).
    private static func transferTimeout(_ size: UInt64) -> Duration {
        .seconds(60) + .seconds(Int64(size / 10_000_000))
    }
}

// MARK: - Request params

private struct ExecRequest: Decodable {
    var argv: [String]?
    var shell: String?
    var runAs: AgentRunAs?
    var cwd: String?
    var env: [String: String]?
    var timeoutMs: UInt64?
    var stdin: Bool?
    /// Text for the command's stdin, given with it (at most 64 KiB).
    var input: String?
    /// Open it on the user's desktop: no output, the call returns at once.
    var desktop: Bool?

    enum CodingKeys: String, CodingKey {
        case argv, shell, cwd, env, timeoutMs, stdin, input, desktop
        case runAs = "as"
    }

    var agentParams: AgentExecStartParams {
        AgentExecStartParams(
            argv: argv, shell: shell, env: env, cwd: cwd, as: runAs ?? .user, stdin: (stdin ?? false) || input != nil,
            timeoutMs: timeoutMs, desktop: desktop == true ? true : nil)
    }
}

private struct ExecInput: Decodable {
    var execId: UInt32
    var dataB64: String?
    var eof: Bool?
}

private struct ExecSignal: Decodable {
    var execId: UInt32
    var signal: AgentSignal
}
