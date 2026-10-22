import Darwin
import Foundation
import VMPaneControl
import VMPaneCore

/// The agent kill switch in this helper (`KillSwitch`). Read at start and on every change of VMPane's folder
/// (kqueue), and once a second for edits in place. When it engages, every client that is not the app is refused,
/// its connections close, the commands it started are killed, its file transfers stop, and port forwards that
/// agents added are taken down; they come back when the app releases it.
extension HelperController {
    func startKillSwitch() {
        killSwitchEngaged = killSwitchReadsEngaged()
        let folder = open(prepared.runFiles.paths.root.path, O_EVTONLY)
        if folder >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: folder, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .global())
            let changed: @Sendable () -> Void = { [weak self] in Task { await self?.killSwitchChanged() } }
            source.setEventHandler(handler: changed)
            source.setCancelHandler { close(folder) }
            source.resume()
            killSwitchWatch = source
        }
        killSwitchPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.killSwitchChanged()
            }
        }
    }

    func stopKillSwitchWatch() {
        killSwitchWatch?.cancel()
        killSwitchWatch = nil
        killSwitchPoll?.cancel()
        killSwitchPoll = nil
    }

    func killSwitchChanged() async {
        let engaged = killSwitchReadsEngaged()
        guard engaged != killSwitchEngaged else { return }
        killSwitchEngaged = engaged
        Self.log.notice("agent kill switch \(engaged ? "engaged" : "released", privacy: .public)")
        if engaged { await stopAgents() }
        await applyForwardsAllowedNow()
        broadcastAgentActivity()
    }

    /// The switch as checked with the key this helper holds (see `effectivePolicy`).
    private func killSwitchReadsEngaged() -> Bool {
        if policyKey == nil { policyKey = PolicyKeyFile(paths: prepared.runFiles.paths).key(create: false) }
        return KillSwitch.isEngaged(paths: prepared.runFiles.paths, key: policyKey)
    }

    /// Ends everything agents are doing here.
    func stopAgents() async {
        agentGeneration += 1
        await releaseHeldInput()
        if confirming { await confirmationDismiss?() }  // an open question is a no now
        if let owner = dropOwner, identities[owner]?.identity != .ui { dropTask?.cancel() }
        let agents = identities.values.filter { $0.identity != .ui }
        await agentExecs.killAgents()
        // Closed a moment later, so an answer on its way (the agent's own mcp.disableAll) still goes out; meanwhile
        // every request on them is refused.
        let connections = agents.compactMap(\.connection)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            for connection in connections { connection.close() }
        }
    }

    /// For an agent's file transfer: true once the kill switch has stopped agents since it began.
    func agentStop(_ owner: ControlConnection) -> (@Sendable () async -> Bool)? {
        guard identity(of: owner).identity != .ui else { return nil }
        let started = agentGeneration
        return { [weak self] in await self?.agentGeneration != started }
    }

    /// The port forwards in effect now: all of them, or only the user's while agents are stopped.
    func forwardsAllowedNow() -> [Extensible<PortForwardConfig>] {
        killSwitchEngaged ? config.portForwards.filter { $0.origin == .user } : config.portForwards
    }

    /// Puts the allowed forwards in place on the running VM (VZ: the helper's listeners; QEMU: its NAT).
    func applyForwardsAllowedNow() async {
        guard state == .running || state == .paused else { return }
        var allowed = config
        allowed.portForwards = forwardsAllowedNow()
        if backend?.kind == .qemu {
            _ = await backend?.applyLive(allowed, paths: ["portForwards"])
        } else {
            _ = await applyForwards((try? PortRule.rules(allowed.portForwards)) ?? [])
        }
    }

    /// `mcp.disableAll` (anyone) and `mcp.enableAll` (the app).
    func killSwitchRequest(engage: Bool) async -> Result<JSONValue, RPCError> {
        do {
            if engage {
                try KillSwitch.engage(paths: prepared.runFiles.paths)
            } else {
                try KillSwitch.release(paths: prepared.runFiles.paths)
            }
        } catch {
            return .failure(RPCError(.internalError, "cannot write the kill switch: \(error)"))
        }
        await killSwitchChanged()
        return .success(["engaged": .bool(engage)])
    }
}
