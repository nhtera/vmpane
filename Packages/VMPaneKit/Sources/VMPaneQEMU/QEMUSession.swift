import Foundation
import VMPaneCore
import os

/// The running VM's processes and QMP connection. One start at a time; everything on this actor.
actor QEMUSession {
    static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "qemu")

    struct Running {
        let qemu: ProcessRecord
        let swtpm: ProcessRecord?
        let qmp: QMPClient
        let layout: QEMULayout
    }

    var config: VMConfigV1
    private var processes: QEMUProcesses
    private let resolveInstallation: @Sendable () throws -> QEMUInstallation
    private let events: AsyncStream<BackendEvent>.Continuation
    var running: Running?
    /// Why QEMU is about to exit (a stop request, the guest powering off); nil means unexpected.
    private var exitReason: String?
    /// Set when the VM must be reported as failed when QEMU exits (e.g. the TPM went away).
    private var failure: String?
    var displaySize: (width: Int, height: Int)?
    /// When `displaySize` was read (screendump).
    var displaySizeAge: ContinuousClock.Instant?
    var pressedButtons = 0
    private let space: QEMUBackend.SpacePolicy
    /// Runs before QEMU is told to quit: the helper disconnects its SPICE client (QEMU's spice-server can hang
    /// in its cleanup while a client is connected).
    private var beforeQuit: (@Sendable () async -> Void)?

    func setBeforeQuit(_ hook: @escaping @Sendable () async -> Void) { beforeQuit = hook }
    /// The guest is paused because its volume is (nearly) full; `resume` checks the space first.
    private var pausedForSpace = false
    /// The `hostfwd` rules active on the first NIC (`tcp:127.0.0.1:8080-:80`).
    var forwards: [String] = []

    init(
        config: VMConfigV1, processes: QEMUProcesses, space: QEMUBackend.SpacePolicy,
        resolveInstallation: @escaping @Sendable () throws -> QEMUInstallation, events: AsyncStream<BackendEvent>.Continuation
    ) {
        self.config = config
        self.processes = processes
        self.space = space
        self.resolveInstallation = resolveInstallation
        self.events = events
    }

    var qmp: QMPClient? { running?.qmp }

    func start(_ options: StartOptions) async throws {
        guard running == nil else { throw QEMUBackendError.alreadyRunning }
        if let next = options.config { config = next }
        var processes = processes
        processes.layoutInstallation(try resolveInstallation())
        try FileManager.default.createDirectory(
            at: processes.layout.runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        processes.layout = try processes.layout.resolved()
        self.processes = processes
        let layout = processes.layout
        try QEMUFirmware.ensureVariables(layout)
        try QEMUFirmware.prepareCode(layout)
        let arguments = try QEMUArgvBuilder.arguments(config, layout: layout, incoming: options.stateDirectory != nil)

        exitReason = nil
        failure = nil
        displaySize = nil
        pressedButtons = 0
        pausedForSpace = false
        forwards =
            config.network.contains { $0.mode == .nat } ? config.portForwards.compactMap { try? QEMUArgvBuilder.hostForward($0) } : []
        var swtpm: (ProcessRecord, ChildExitWatcher)?
        var qemu: ProcessRecord?
        do {
            if config.qemu?.tpm == true { swtpm = try await processes.startSwtpm() }
            let (record, qemuExit) = try processes.startQEMU(arguments)
            qemu = record
            let qmp = try await connect(layout.qmpSocket, while: qemuExit, log: layout.qemuLog)
            if let saved = options.stateDirectory {
                try await QEMUState.load(qmp, from: layout.path(of: saved), memoryMiB: config.memory.mib)
                try await qmp.execute("cont")
            }
            running = Running(qemu: record, swtpm: swtpm?.0, qmp: qmp, layout: layout)
            watch(qmp)
            watchSpace(record)
            Task { await self.qemuExited(await qemuExit.wait(), qemu: record) }
            if let (record, watcher) = swtpm { Task { await self.swtpmExited(await watcher.wait(), swtpm: record) } }
        } catch {
            // Nothing half-started stays behind, nor in the children record.
            let started = [qemu, swtpm?.0].compactMap { $0 }
            let forget = processes.forget
            await Blocking.run {
                for child in started {
                    child.terminate()
                    forget(child)
                }
            }
            throw error
        }
    }

    /// Connects to QMP, failing at once if QEMU exits first (a bad option, a missing file).
    private func connect(_ socket: URL, while watcher: ChildExitWatcher, log: URL) async throws -> QMPClient {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            if let exit = watcher.exit {
                throw QEMUStartError.exitedDuringStart(program: "QEMU", exit: exit, log: QEMUProcesses.tail(of: log))
            }
            do {
                return try await QMPClient.connect(to: socket, timeout: .seconds(2))
            } catch let error as POSIXError where [.ENOENT, .ECONNREFUSED].contains(error.code) {
                guard ContinuousClock.now < deadline else { throw QEMUStartError.timedOut("QMP") }
            } catch {
                // QEMU may exit right after opening the socket (a bad option found late): report that.
                for _ in 0..<50 where watcher.exit == nil { try await Task.sleep(for: .milliseconds(20)) }
                if let exit = watcher.exit {
                    throw QEMUStartError.exitedDuringStart(program: "QEMU", exit: exit, log: QEMUProcesses.tail(of: log))
                }
                throw error
            }
        }
    }

    /// QMP events → backend events, only while `qmp` is the running QEMU's connection.
    private func watch(_ qmp: QMPClient) {
        Task {
            for await event in qmp.events where self.running?.qmp === qmp {
                self.handle(event)
            }
        }
    }

    func handle(_ event: QMPEvent) {
        switch event.name {
        case "STOP" where exitReason != nil: break  // QEMU is going away: the stop is not a pause
        case "STOP" where pausedForSpace: events.yield(.diskFull(message: Self.diskFullMessage))
        case "STOP": events.yield(.paused)
        case "BLOCK_IO_ERROR" where event.data["action"] == "stop":
            // A disk with a stop-on-ENOSPC policy (virtio, USB) paused the guest; STOP follows.
            Self.log.error("block I/O error: \(String(describing: event.data), privacy: .public)")
            pausedForSpace = true
        case "RESUME": events.yield(.resumed)
        case "SHUTDOWN":
            // The guest powered off (a normal stop) or QEMU is shutting down. QEMU runs with -no-shutdown, so
            // it waits here until the backend has disconnected the display, then quits.
            if exitReason == nil {
                exitReason =
                    event.data["guest"] == true ? "guest powered off" : "QEMU shut down (\(event.data["reason"]?.stringValue ?? "unknown"))"
            }
            if event.data["guest"] == true, let current = running { Task { await self.quit(current) } }
        case "GUEST_PANICKED":
            // With -no-shutdown a panic only pauses QEMU: power it off, so the VM can be started again.
            Self.log.error("guest panicked: \(String(describing: event.data), privacy: .public)")
            guard exitReason == nil, let current = running else { break }
            failure = "Windows stopped with an error (guest panic). Start the VM again; the logs have details."
            exitReason = "guest panic"
            Task { await self.quit(current) }
        default:
            break
        }
    }

    private func qemuExited(_ exit: ChildExit, qemu: ProcessRecord) async {
        guard let current = running, current.qemu == qemu else { return }
        running = nil
        current.qmp.close()
        let forget = processes.forget
        await Blocking.run {
            current.swtpm?.terminate()  // swtpm --terminate exits with QEMU; make sure
            for child in [current.qemu] + (current.swtpm.map { [$0] } ?? []) { forget(child) }
        }
        if let failure {
            events.yield(.failed(message: failure))
        } else if let reason = exitReason {
            events.yield(.stopped(reason: reason))
        } else if exit == .exited(0) {
            events.yield(.stopped(reason: "QEMU exited"))
        } else {
            let tail = QEMUProcesses.tail(of: current.layout.qemuLog, lines: 20)
            Self.log.error("QEMU \(exit.description, privacy: .public)")
            events.yield(.failed(message: "QEMU \(exit)\(tail.isEmpty ? "" : ": \(tail)")"))
        }
    }

    /// The TPM must not disappear under a running Windows (BitLocker): stop QEMU and report the failure.
    /// swtpm also exits (--terminate) right after QEMU does, so give QEMU's own exit a moment to be seen.
    private func swtpmExited(_ exit: ChildExit, swtpm: ProcessRecord) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard let current = running, current.swtpm == swtpm, exitReason == nil, current.qemu.isAlive else { return }
        failure = "The VM's TPM emulator stopped (\(exit)); the VM was powered off to protect its TPM state."
        exitReason = "TPM emulator stopped"
        await quit(current)
    }

    /// Quits QEMU (after `beforeQuit`) and waits until it has exited (up to 15 s); terminates it when QMP no
    /// longer answers or it does not exit, so the bundle lock never stays with a QEMU that hangs on its way out.
    private func quit(_ current: Running) async {
        await beforeQuit?()
        if (try? await current.qmp.execute("quit")) != nil {
            let deadline = ContinuousClock.now + .seconds(15)
            while running?.qemu == current.qemu, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard running?.qemu == current.qemu else { return }
            Self.log.error("QEMU did not exit after quit: terminating it")
        }
        _ = await Blocking.run { current.qemu.terminate() }
    }

    static let diskFullMessage = "The disk holding this VM is almost full, so the VM was paused. Free some space, then resume it."

    /// Every `space.interval` while QEMU runs: pause the guest before its volume fills up.
    private func watchSpace(_ qemu: ProcessRecord) {
        Task {
            while let current = self.running, current.qemu == qemu {
                if !self.pausedForSpace, let free = try? self.space.freeBytes(current.layout.bundleDirectory),
                    free < self.space.pauseBelow
                {
                    Self.log.error("only \(free >> 20, privacy: .public) MiB free: pausing the guest")
                    self.pausedForSpace = true
                    if (try? await current.qmp.execute("query-status"))?["running"] == true {
                        _ = try? await current.qmp.execute("stop")  // STOP → diskFull
                    } else {
                        self.events.yield(.diskFull(message: Self.diskFullMessage))
                    }
                }
                try? await Task.sleep(for: self.space.interval)
            }
        }
    }

    /// Continues the guest; after a disk-full pause only once enough space is free again.
    func resume() async throws {
        guard let current = running else { throw QEMUBackendError.notRunning }
        if pausedForSpace {
            let free = try space.freeBytes(current.layout.bundleDirectory)
            guard free >= space.resumeFrom else { throw InsufficientSpace(requiredBytes: space.resumeFrom, availableBytes: free) }
            pausedForSpace = false
        }
        try await current.qmp.execute("cont")
    }

    func execute(_ command: String, _ arguments: [String: JSONValue]? = nil) async throws {
        guard let qmp = running?.qmp else { throw QEMUBackendError.notRunning }
        try await qmp.execute(command, arguments)
    }

    func stop(_ mode: StopMode) async throws {
        guard let current = running else { throw QEMUBackendError.notRunning }
        switch mode {
        case .graceful:
            // ACPI power button: Windows shuts down (can take a minute), then QEMU is quit. A paused guest
            // cannot see the button: one paused for a full disk (or a restore) is powered off, one the
            // user paused continues first.
            let status = try await current.qmp.execute("query-status")
            if status["running"] != true {
                guard status["status"] == "paused", !pausedForSpace else {
                    exitReason = exitReason ?? "powered off while paused"
                    await quit(current)
                    return
                }
                try await current.qmp.execute("cont")
            }
            try await current.qmp.execute("system_powerdown")
        case .force:
            exitReason = exitReason ?? "forced off"
            await quit(current)
        }
    }

    /// Saves RAM state of the paused VM (pausing it if needed, S12: never migrate a running guest).
    func saveState(to directory: URL) async throws {
        guard let current = running else { throw QEMUBackendError.notRunning }
        if try await current.qmp.execute("query-status")["running"] == true { try await current.qmp.execute("stop") }
        let target = current.layout.path(of: directory).appendingPathComponent(QEMUState.fileName)
        try await QEMUState.save(current.qmp, to: target, memoryMiB: config.memory.mib)
    }

    /// Saves RAM state as `state.qemu.partial`, renames it, then powers QEMU off. On failure the partial file
    /// is removed and the guest continues (the backend contract: never left paused).
    func suspend(to directory: URL) async throws {
        guard let current = running else { throw QEMUBackendError.notRunning }
        let directory = current.layout.path(of: directory)
        let final = directory.appendingPathComponent(QEMUState.fileName)
        let partial = directory.appendingPathComponent(QEMUState.fileName + ".partial")
        var wasRunning = false
        do {
            wasRunning = try await current.qmp.execute("query-status")["running"] == true
            if wasRunning { try await current.qmp.execute("stop") }
            try await QEMUState.save(current.qmp, to: partial, memoryMiB: config.memory.mib)
            try FileManager.default.moveItem(at: partial, to: final)
            try DurableWrite.syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            // Back to how it was: running again only if it ran, and never past a disk-full pause.
            if wasRunning, !pausedForSpace { _ = try? await current.qmp.execute("cont") }
            throw error
        }
        // Returns once QEMU and swtpm are gone: the state files must not change after this, and the bundle lock
        // must not stay with a QEMU that is still there (`quit` waits, and terminates a QEMU that hangs).
        exitReason = "suspended"
        await quit(current)
    }
}
