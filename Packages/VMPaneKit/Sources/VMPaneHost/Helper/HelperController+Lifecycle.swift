import Foundation
import VMPaneControl
import VMPaneCore
import os

/// VM lifecycle in the helper. State changes come from the backend's events; a request only checks that
/// it is allowed now, applies its intermediate state (starting, suspending, stopping) and calls the
/// backend. A backend event that repeats the current state, or does not fit it, is logged and ignored.
extension HelperController {
    static let log = Logger(subsystem: VMPane.SigningIdentifier.helper, category: "lifecycle")

    /// Reads `backend.events` (single consumer) for the helper's lifetime.
    func startEventPump() {
        guard let backend, pumpTask == nil else { return }
        let events = backend.events
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.apply(event)
            }
        }
    }

    func apply(_ event: BackendEvent) {
        switch event {
        case .started: transition(.started)
        case .paused: transition(.paused)
        case .resumed: transition(.resumed)
        case .suspended: transition(.suspended)
        case .stopped(let reason):
            transition(.stopped, reason: reason)
            if afterStop != nil, state == .stopped { Task { await self.vmStopped() } }
            if windowsInstall != nil, state == .stopped { Task { await self.installStopped() } }
        case .failed(let message): transition(.failed, reason: message)
        case .diskFull(let message):
            // Paused with the reason; "Resume" continues once space has been freed. Already paused: the
            // transition announces nothing, so the reason is broadcast here.
            if state != .paused {
                transition(.paused, reason: message)
            } else {
                server?.broadcast(
                    topic: "vm", method: ControlNotification.vmStateChanged.rawValue,
                    params: ["state": .string(state.rawValue), "reason": .string(message)])
            }
        case .guestReset:
            Self.log.info("the guest restarted")
            if windowsInstall != nil { Task { await self.installGuestReset() } }
        case .installProgress(let fraction, let message):
            server?.broadcast(
                topic: "install", method: ControlNotification.installProgress.rawValue,
                params: ["phase": "install", "percent": .int(Int64(fraction * 100)), "message": .string(message)])
        case .consoleOutput(let data):
            server?.broadcast(
                topic: "console", method: ControlNotification.consoleOutput.rawValue,
                params: ["dataB64": .string(data.base64EncodedString())])
        }
    }

    /// Applies `event` if it fits the current state and announces the change.
    @discardableResult
    func transition(_ event: HelperStateMachine.Event, reason: String? = nil) -> Bool {
        switch HelperStateMachine.transition(state, event) {
        case .success(let next):
            guard next != state else { return true }
            state = next
            stateContinuation.yield(next)
            server?.broadcast(
                topic: "vm", method: ControlNotification.vmStateChanged.rawValue,
                params: ["state": .string(next.rawValue), "reason": reason.map { .string($0) } ?? .null])
            return true
        case .failure:
            Self.log.notice("ignored \(event.rawValue, privacy: .public) in state \(self.state.rawValue, privacy: .public)")
            return false
        }
    }

    // MARK: - Requests

    private struct StartParams: Decodable { var headless: Bool? }
    private struct StopParams: Decodable { var mode: StopMode? }

    func lifecycle(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        guard let backend else {
            return .failure(RPCError(.backendUnavailable, "no \(config.backend.rawValue) backend in this build"))
        }
        let request: HelperStateMachine.Event =
            switch ControlMethod(rawValue: method) {
            case .vmStart?: .start
            case .vmPause?: .pause
            case .vmResume?: .resume
            case .vmSuspend?: .suspend
            default: .stop
            }
        guard HelperStateMachine.allowedRequests(in: state).contains(request) else {
            return .failure(RPCError(.invalidState, "cannot \(request.rawValue) while \(state.rawValue)"))
        }
        do {
            switch request {
            case .start:
                let headless = try RPCParams.decode(StartParams.self, from: params).get().headless ?? false
                try await startVM(backend, headless: headless)
            case .pause:
                try await backend.pause()
                transition(.paused)
            case .resume:
                try await backend.resume()
                transition(.resumed)
            case .suspend:
                let discarded = pendingRestart
                try await suspendVM(backend)
                if discarded {
                    return .success([
                        "state": .string(state.rawValue),
                        "message": "Saved settings change this VM's hardware, so the next start boots fresh instead of resuming.",
                    ])
                }
            default:
                let mode = try RPCParams.decode(StopParams.self, from: params).get().mode ?? .graceful
                transition(.stop)
                try await backend.stop(mode)  // `.stopped` arrives as an event (graceful stops take a while)
            }
            return .success(["state": .string(state.rawValue)])
        } catch let error as RPCError {
            return .failure(error)
        } catch let error as InsufficientSpace {
            return .failure(
                RPCError(.insufficientSpace, "needs \(error.requiredBytes >> 30) GiB free, \(error.availableBytes >> 30) GiB available"))
        } catch {
            if state == .starting || state == .stopping { transition(.failed, reason: String(describing: error)) }
            return .failure(RPCError(.internalError, String(describing: error)))
        }
    }

    // MARK: - Start / suspend

    var stateDirectory: URL { prepared.lock.bundle.stateDirectory }

    /// Starts the VM, resuming saved RAM state when the generation rule allows; otherwise (or if the
    /// restore fails) a cold boot, and the state is deleted: one rule, no retry. The exception is a locked
    /// Mac: the state cannot be decrypted until it is unlocked, so it is kept and the start fails (`macLocked`).
    /// Returns whether the saved state was resumed.
    @discardableResult
    func startVM(_ backend: VMBackend, headless: Bool) async throws -> Bool {
        lastStartHeadless = headless
        transition(.start)
        await installWillStart()
        let decision = await savedStateDecision()
        if decision == .discard { await clearSavedState() }
        var resumed = decision == .resume
        do {
            try await backend.start(StartOptions(headless: headless, stateDirectory: resumed ? stateDirectory : nil, config: config))
        } catch  where resumed && (error is SavedStateLocked || (backend.kind == .vz && isSessionLocked())) {
            Self.log.notice("restore failed while the Mac is locked; state kept: \(String(describing: error), privacy: .public)")
            transition(.stopped)
            throw RPCError(
                .macLocked,
                "This Mac is locked. macOS keeps the VM's saved memory encrypted until you unlock it; unlock, then start the VM again.")
        } catch  where resumed {
            Self.log.notice("restoring saved state failed, cold boot: \(String(describing: error), privacy: .public)")
            resumed = false
            await clearSavedState()
            try await backend.start(StartOptions(headless: headless, config: config))
        }
        runningConfig = config
        transition(.started)
        installDidStart(backend)
        if resumed { await clearSavedState() }  // the running VM has moved on from it
        if let updated = afterStart?(config) {
            let lock = prepared.lock
            do {
                try await Blocking.run { try ConfigStore.save(updated, holding: lock) }
                config = updated
            } catch {
                Self.log.error("cannot save the config after start: \(String(describing: error), privacy: .public)")
            }
        }
        return resumed
    }

    /// The VM stopped: save `afterStop`'s config change, if any (next start uses it). Not while saved RAM
    /// state waits: a device change would discard it.
    func vmStopped() async {
        guard let hook = afterStop, state == .stopped else { return }
        let directory = stateDirectory
        let hasSavedState = await Blocking.run { !((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty }
        guard !hasSavedState else { return }
        let current = config
        // A start may have run while the hook read the disk: then it waits for the next stop.
        guard let updated = await Blocking.run({ hook(current) }), state == .stopped, config == current else { return }
        config = updated  // before saving, so a start arriving meanwhile already uses it
        let lock = prepared.lock
        do {
            try await Blocking.run { try ConfigStore.save(updated, holding: lock) }
        } catch {
            Self.log.error("cannot save the config after the VM stopped: \(String(describing: error), privacy: .public)")
        }
        server?.broadcast(
            topic: "install", method: ControlNotification.installProgress.rawValue,
            params: ["phase": "complete", "percent": 100, "message": "Installation finished; installer media removed"])
    }

    func writeStateMeta() async throws {
        let (bundle, directory, hash) = (prepared.lock.bundle, stateDirectory, DeviceSet(runningConfig ?? config).hash)
        try await Blocking.run {
            let meta = StateMeta(
                generationId: try Generation.read(from: bundle.generationURL).generationId,
                deviceSetHash: hash, hostBuild: HelperController.hostBuild, backendVersion: VMPane.version)
            try DurableWrite.write(CanonicalJSON.encode(meta), to: directory.appendingPathComponent(StateMeta.fileName))
        }
    }

    /// Saves RAM state and stops. `suspend.json` is written last: it is the commit marker.
    func suspendVM(_ backend: VMBackend) async throws {
        let bundle = prepared.lock.bundle
        let memory = UInt64(config.memory.mib) << 20
        let checkSpace = checkSpace
        try await Blocking.run { try checkSpace(memory, bundle.url) }
        transition(.suspend)
        await clearSavedState()
        do {
            try await backend.suspend(to: stateDirectory)
            let meta = StateMeta(
                generationId: try Generation.read(from: bundle.generationURL).generationId,
                deviceSetHash: DeviceSet(runningConfig ?? config).hash, hostBuild: Self.hostBuild, backendVersion: VMPane.version)
            try DurableWrite.write(CanonicalJSON.encode(meta), to: stateDirectory.appendingPathComponent(StateMeta.fileName))
        } catch {
            await clearSavedState()
            transition(.resumed, reason: "suspend failed")  // the backend contract: still running
            throw error
        }
        transition(.suspended)
    }

    func savedStateDecision() async -> SavedStateDecision {
        let (directory, bundle, hash) = (stateDirectory, prepared.lock.bundle, DeviceSet(config).hash)
        return await Blocking.run {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let meta = (try? Data(contentsOf: directory.appendingPathComponent(StateMeta.fileName)))
                .flatMap { try? CanonicalJSON.decoder().decode(StateMeta.self, from: $0) }
            guard let generation = try? Generation.read(from: bundle.generationURL) else { return entries.isEmpty ? .none : .discard }
            return SavedStateRule.decide(stateMeta: meta, stateExists: !entries.isEmpty, current: generation, deviceSetHash: hash)
        }
    }

    func clearSavedState() async {
        let directory = stateDirectory
        await Blocking.run {
            for entry in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    // MARK: - Shutdown

    /// Before the helper exits: suspend (if the VM's close action says so and the backend can), else a
    /// graceful stop, then a forced one. The bundle lock is released only after this.
    func stopBackendForShutdown() async {
        guard let backend, [.starting, .running, .paused, .stopping].contains(state) else { return }
        if config.ui.closeAction == .suspend, backend.capabilities.contains(.suspend), state != .starting,
            (try? await suspendVM(backend)) != nil
        {
            return
        }
        if state != .stopping {
            transition(.stop)
            try? await backend.stop(.graceful)
        }
        if await waitForState(.stopped, timeout: gracefulStopTimeout) { return }
        try? await backend.stop(.force)
        _ = await waitForState(.stopped, timeout: .seconds(10))
    }

    /// Waits (with actor reentrancy, so events keep arriving) until `target` or `timeout`.
    func waitForState(_ target: VMRunState, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while state != target {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
