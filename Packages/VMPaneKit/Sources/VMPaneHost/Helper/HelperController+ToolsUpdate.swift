import Foundation
import VMPaneControl
import VMPaneCore

/// The guest tools keep up with VMPane: a Linux or Windows agent older than this helper updates itself from the
/// runtime's `GuestTools` once it connects, through the agent (root, SYSTEM), with no password. Its installer runs
/// out of the agent's reach (`systemd-run`; a PowerShell of its own on Windows), since the install restarts the agent
/// and the agent's commands end with it. Once per helper run; never while an AI agent changes something or a command
/// runs in the guest; `agent.autoUpdate: false` turns it off.
extension HelperController {
    struct ToolsUpdateState {
        /// An update to this helper's version was started (a failed one is not retried by itself).
        var tried = false
        var running = false
        /// The installer runs: the agent goes away and comes back. Agents' requests for it wait, a graceful stop too.
        var installing = false
        /// How long after a connect it waits (the guest's first moments: shares, clock, the person signing in).
        var settle: Duration = .seconds(20)
        /// How long it waits for the updated agent to connect.
        var reconnect: Duration = .seconds(120)
    }

    /// Whether an agent of `version` is older than this helper's (`agent.status`'s `outdated`).
    static func toolsOutdated(_ version: String) -> Bool {
        guard let agent = ReleaseVersion(version), let helper = ReleaseVersion(VMPane.version) else { return false }
        return agent < helper
    }

    /// Whether the connected agent (`peer`) is due an update from this helper's tools (`manual`: the person asked,
    /// whatever the VM's switch says).
    func toolsUpdateDue(_ peer: AgentConnection.Peer, manual: Bool = false) -> Bool {
        guard manual || config.agent.updatesTools, !toolsUpdate.running, !toolsUpdate.tried,
            peer.hello.caps?.contains(AgentCap.exec) == true, peer.hello.caps?.contains(AgentCap.file) == true,
            let os = GuestOS(rawValue: peer.hello.os), GuestToolsPackage.installer(for: os) != nil
        else { return false }
        return Self.toolsOutdated(peer.hello.agentVersion)
    }

    /// After a connect (or when the person asks, `manual`): updates an older agent once nothing uses it.
    func updateToolsIfOlder(_ connection: AgentConnection, peer: AgentConnection.Peer, manual: Bool = false) async {
        guard toolsUpdateDue(peer, manual: manual), let os = GuestOS(rawValue: peer.hello.os) else { return }
        toolsUpdate.running = true
        defer { toolsUpdate.running = false }
        let package: GuestToolsPackage
        do {
            package = try await Blocking.run { [runtime = toolsRuntime] in try GuestToolsPackage.verified(os, runtime: runtime) }
        } catch {
            Self.log.notice("guest tools not updated: \(String(describing: error), privacy: .public)")
            return
        }
        if !manual { try? await Task.sleep(for: toolsUpdate.settle) }
        // The agent reconnected meanwhile (a reboot, a restore): the update goes on with the new connection.
        guard await waitUntilAgentIsFree(connection, manual: manual) else { return await updateOnCurrentConnection(manual: manual) }
        toolsUpdate.tried = true
        Self.log.notice("updating the guest tools from \(peer.hello.agentVersion, privacy: .public) to \(VMPane.version, privacy: .public)")
        let started = ContinuousClock.now
        broadcastToolsUpdate("updating", message: "Updating the guest tools to \(VMPane.version)…")
        do {
            let launch =
                os == .windows
                ? try await stageWindowsTools(package, on: connection) : try await stageLinuxTools(package, on: connection)
            guard await waitUntilAgentIsFree(connection, manual: manual) else {
                throw RPCError(.agentUnavailable, "the guest agent reconnected before the update could start")
            }
            toolsUpdate.installing = true
            defer { toolsUpdate.installing = false }
            _ = try await guestOutput(launch, windows: os == .windows, on: connection)
            try await waitForUpdatedAgent(replacing: connection, os: os)
            broadcastToolsUpdate("updated", message: "Guest tools updated to \(VMPane.version)")
            auditToolsUpdate(from: peer.hello.agentVersion, started: started, failure: nil)
        } catch {
            let reason = ErrorText.readable(error)
            Self.log.error("guest tools update failed: \(reason, privacy: .public)")
            broadcastToolsUpdate("failed", message: "The guest tools could not update: \(reason)")
            auditToolsUpdate(from: peer.hello.agentVersion, started: started, failure: reason)
        }
    }

    /// The runtime copy this helper runs from (its `GuestTools`).
    var toolsRuntime: URL { prepared.runFiles.paths.runtime(version: runtimeVersion) }

    /// Something uses the agent now: an AI agent's request runs or changed something in the last seconds (reading,
    /// like polling the VM's status, does not count), the person took over or agents are stopped, a question is up,
    /// or a command, a transfer or typing is under way.
    func toolsUpdateMustWait() async -> Bool {
        let lastChange = activity.recent.first { !Self.readOnlyMethods.contains($0.method) }
        let acting = lastChange.map { Date().timeIntervalSince($0.when) < AgentActivityState.acting } ?? false
        if acting || agentRequestsInFlight > 0 || activity.takenOver || killSwitchEngaged || confirming || batching || signingIn
            || inputsInFlight > 0
        {
            return true
        }
        if dropTask != nil || state != .running { return true }
        return await agentExecs.runsCommands
    }

    /// Waits while something uses the agent; false when `connection` is no longer the agent's or the update was
    /// turned off meanwhile (unless the person asked for it).
    private func waitUntilAgentIsFree(_ connection: AgentConnection, manual: Bool) async -> Bool {
        while await toolsUpdateMustWait() {
            guard await agentHub.connection === connection else { return false }
            try? await Task.sleep(for: .seconds(10))
        }
        return await agentHub.connection === connection && (manual || config.agent.updatesTools)
    }

    /// Starts over on the agent connected now, if any (a later connect starts it otherwise).
    private func updateOnCurrentConnection(manual: Bool) async {
        guard let connection = await agentHub.connection, let peer = await agentHub.status.peer else { return }
        Task { await self.updateToolsIfOlder(connection, peer: peer, manual: manual) }  // runs once this one has returned
    }

    /// `vm.tools.update` or `vm.tools.attach`, the VM menu's Update and Install Guest Tools.
    func toolsRequest(_ method: String) async -> Result<JSONValue, RPCError> {
        method == ControlMethod.vmToolsAttach.rawValue ? await toolsAttachRequest() : await toolsUpdateRequest()
    }

    /// `vm.tools.update` (Update Guest Tools in the VM's window): an older Linux or Windows agent updates now, even
    /// after a failed try or with the VM's switch off.
    private func toolsUpdateRequest() async -> Result<JSONValue, RPCError> {
        guard let connection = await agentHub.connection, let peer = await agentHub.status.peer else {
            return .failure(RPCError(.agentUnavailable, "the guest tools are not running in this VM: install them first"))
        }
        guard let os = GuestOS(rawValue: peer.hello.os), GuestToolsPackage.installer(for: os) != nil else {
            return .failure(RPCError(.invalidState, "a macOS VM updates its guest tools by hand (VMPane Agent.pkg)"))
        }
        guard peer.toolsOutdated else { return .success(["started": false, "version": .string(peer.hello.agentVersion)]) }
        guard peer.hello.caps?.contains(AgentCap.exec) == true, peer.hello.caps?.contains(AgentCap.file) == true else {
            return .failure(RPCError(.agentUnavailable, "these guest tools are too old to update themselves: install them again"))
        }
        if !toolsUpdate.running {
            toolsUpdate.tried = false
            Task { await self.updateToolsIfOlder(connection, peer: peer, manual: true) }
        }
        return .success(["started": true, "version": .string(peer.hello.agentVersion)])
    }

    /// `vm.tools.attach` (Install Guest Tools in a Windows VM's window): the guest-tools disc from the VM's next
    /// start (a running QEMU VM takes no new disc, and a restart of Windows keeps the same QEMU).
    private func toolsAttachRequest() async -> Result<JSONValue, RPCError> {
        guard config.os == .windows, config.backend == .qemu else {
            return .failure(RPCError(.invalidState, "only Windows VMs take the guest-tools disc"))
        }
        guard config.install == nil, [.stopped, .running, .paused, .error].contains(state) else {
            return .failure(
                RPCError(.invalidState, "the guest-tools disc can be attached once the VM is installed and not starting or stopping"))
        }
        let disc = toolsRuntime.appendingPathComponent("GuestTools/vmpane-guest-tools-windows.iso")
        guard FileManager.default.fileExists(atPath: disc.path) else {
            return .failure(RPCError(.backendUnavailable, "this VMPane has no Windows guest-tools disc"))
        }
        let lock = prepared.lock
        do {
            let iso = try await Blocking.run { try WindowsInstall.placeTools(disc, in: lock.bundle) }
            // From the config as it is now: anything applied during the copy stays.
            let updated = WindowsInstall.withTools(config, iso: iso)
            try await Blocking.run { try ConfigStore.save(updated, holding: lock) }
            config = updated
            return .success(["nextBoot": .bool(state != .stopped)])
        } catch {
            return .failure(RPCError(.internalError, "the guest-tools disc could not be attached: \(ErrorText.readable(error))"))
        }
    }

    /// A graceful `vm.stop` while the installer runs waits for it: a Windows guest stopped mid-install can be left
    /// with no agent at all (the MSI removes the old one first).
    func finishToolsInstallBeforeStop(_ params: JSONValue?) async {
        guard toolsUpdate.installing, params?["mode"] != "force" else { return }
        let deadline = ContinuousClock.now + toolsUpdate.reconnect
        while toolsUpdate.installing, ContinuousClock.now < deadline { try? await Task.sleep(for: .seconds(1)) }
    }

    /// Linux: the files and their `SHA256SUMS` (which `install.sh` checks again) to a fresh root-only folder; returns
    /// the command that runs `install.sh` in a unit of its own and then removes the folder.
    private func stageLinuxTools(_ package: GuestToolsPackage, on connection: AgentConnection) async throws -> String {
        let folder = try await guestOutput("mktemp -d /var/tmp/vmpane-tools.XXXXXX", on: connection)
        do {
            for name in package.files + ["SHA256SUMS"] {
                let source = package.folder.appendingPathComponent(name)
                _ = try await Self.push(FileTransfer(hostPath: source.path, guestPath: "\(folder)/\(name)"), on: connection)
            }
        } catch {
            _ = try? await guestOutput("rm -rf \(Self.shellQuoted(folder))", on: connection)
            throw error
        }
        let unit = "vmpane-tools-update-\(Int(Date().timeIntervalSince1970))"
        let script = "sh \"$0/install.sh\" >/var/log/vmpane-tools-update.log 2>&1; rm -rf \"$0\""
        return "systemd-run --quiet --collect --unit=\(unit) /bin/sh -c \(Self.shellQuoted(script)) \(Self.shellQuoted(folder))"
    }

    /// Windows: the MSI to a fresh folder in Program Files (only SYSTEM and administrators may write there, so no
    /// user of the guest can swap it); returns the command that starts a PowerShell of its own, which checks the MSI
    /// again, runs msiexec, starts the service (the MSI stops it and leaves it stopped) and removes the folder.
    private func stageWindowsTools(_ package: GuestToolsPackage, on connection: AgentConnection) async throws -> String {
        let folder = try await guestOutput(
            "$d = Join-Path $env:ProgramFiles ('VMPane\\update-' + [guid]::NewGuid().ToString('N')); "
                + "New-Item -ItemType Directory $d -ErrorAction Stop | Out-Null; $d",
            windows: true, on: connection)
        let msi = "\(folder)\\vmpane-agent.msi"
        let source = package.folder.appendingPathComponent("vmpane-agent.msi")
        _ = try await Self.push(FileTransfer(hostPath: source.path, guestPath: msi), on: connection)
        let update = """
            $d = '\(folder)'
            $msi = Join-Path $d 'vmpane-agent.msi'
            if ((Get-FileHash $msi -Algorithm SHA256).Hash -ne '\(package.sha256["vmpane-agent.msi"] ?? "")') { exit 2 }
            $log = Join-Path $d 'install.log'
            $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"" -Wait -PassThru
            Start-Service vmpane-agent
            if ($p.ExitCode -eq 0) { Remove-Item -Recurse -Force $d }
            exit $p.ExitCode
            """
        let encoded = Data(update.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
        return "Start-Process powershell.exe -WindowStyle Hidden "
            + "-ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand','\(encoded)'"
    }

    /// A command as root or SYSTEM (sh; PowerShell on Windows): its output, trimmed; throws when it fails (what the
    /// guest printed goes to the log, not to the person).
    private func guestOutput(_ command: String, windows: Bool = false, on connection: AgentConnection) async throws -> String {
        let powershell = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command]
        let params =
            windows
            ? AgentExecStartParams(argv: powershell, as: .admin, timeoutMs: 60000)
            : AgentExecStartParams(shell: command, as: .admin, timeoutMs: 60000)
        let result = try await agentExecs.run(params, on: connection)
        guard result.exited?.code == 0 else {
            let stderr = String(bytes: result.stderr, encoding: .utf8) ?? ""
            Self.log.error("guest tools update: a guest command failed: \(stderr, privacy: .public)")
            throw RPCError(.internalError, "a command in the guest failed")
        }
        return (String(bytes: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits for an agent of this helper's version to connect in place of `old`; when `old` is still there at the
    /// end, the installer did not get as far as restarting it (its log goes to the helper's log).
    private func waitForUpdatedAgent(replacing old: AgentConnection, os: GuestOS) async throws {
        let deadline = ContinuousClock.now + toolsUpdate.reconnect
        while ContinuousClock.now < deadline {
            if let connection = await agentHub.connection, connection !== old,
                let version = await agentHub.status.peer?.hello.agentVersion
            {
                guard ReleaseVersion(version) != nil, !Self.toolsOutdated(version) else {
                    throw RPCError(.internalError, "the guest agent is still \(version) after the update")
                }
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        guard await agentHub.connection === old else {
            throw RPCError(.agentUnavailable, "the guest agent did not come back within \(toolsUpdate.reconnect) of the update")
        }
        let log =
            os == .windows
            ? "Get-ChildItem (Join-Path $env:ProgramFiles 'VMPane\\update-*\\install.log') | Get-Content -Tail 20"
            : "tail -n 20 /var/log/vmpane-tools-update.log"
        if let lines = try? await guestOutput(log, windows: os == .windows, on: old) {
            Self.log.error("guest tools installer log: \(lines, privacy: .public)")
        }
        throw RPCError(.internalError, "the installer did not restart the guest tools")
    }

    private func broadcastToolsUpdate(_ state: String, message: String) {
        server?.broadcast(
            topic: "agent", method: ControlNotification.agentToolsUpdate.rawValue,
            params: ["state": .string(state), "version": .string(VMPane.version), "message": .string(message)])
    }

    /// In the VM's audit log as the app's own action.
    private func auditToolsUpdate(from: String, started: ContinuousClock.Instant, failure: String?) {
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let entry = AuditEntry(
            identity: "ui", kind: "helper", method: ControlNotification.agentToolsUpdate.rawValue,
            args: ["from": .string(from), "to": .string(VMPane.version)], policy: effectivePolicy().level.rawValue,
            result: failure == nil ? "ok" : "error", reason: failure, durationMs: milliseconds)
        do {
            try auditLog.append(entry)
        } catch {
            Self.log.error("the audit log cannot be written: \(String(describing: error), privacy: .public)")
        }
    }

    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension AgentConnection.Peer {
    /// Its agent is older than this helper's (`agent.status`'s `outdated`).
    var toolsOutdated: Bool { HelperController.toolsOutdated(hello.agentVersion) }
}
