import Foundation
import VMPaneCore
import os

public enum QEMUBackendError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRunning
    case alreadyRunning

    public var description: String {
        switch self {
        case .notRunning: "the VM is not running"
        case .alreadyRunning: "the VM is already running"
        }
    }
}

/// `VMBackend` for Windows 11 ARM: `qemu-system-aarch64 -accel hvf` and swtpm as sandboxed child processes,
/// controlled over QMP. The helper owns the window; display and clipboard come from SPICE.
public final class QEMUBackend: VMBackend {
    public let kind = BackendKind.qemu
    public let capabilities: LiveCapabilities = [.pause, .suspend, .liveSnapshot, .screenshot, .input]
    public let events: AsyncStream<BackendEvent>

    let session: QEMUSession

    /// `resolveInstallation` picks and validates the QEMU to run at each start (`QEMUPaths.resolve`).
    public init(
        config: VMConfigV1, processes: QEMUProcesses, resolveInstallation: @escaping @Sendable () throws -> QEMUInstallation
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        events = stream
        session = QEMUSession(config: config, processes: processes, resolveInstallation: resolveInstallation, events: continuation)
    }

    public func start(_ options: StartOptions) async throws { try await session.start(options) }
    public func pause() async throws { try await session.execute("stop") }
    public func resume() async throws { try await session.execute("cont") }

    public func suspend(to stateDirectory: URL) async throws { try await session.suspend(to: stateDirectory) }
    public func saveState(to stateDirectory: URL) async throws { try await session.saveState(to: stateDirectory) }

    public func stop(_ mode: StopMode) async throws { try await session.stop(mode) }
    public func screenshot(maxEdge: Int) async throws -> Screenshot { try await session.screenshot(maxEdge: maxEdge) }
    public func send(_ input: InputEvent) async throws { try await session.send(input) }

    /// QMP for integration hooks and later features (snapshots, live settings).
    var qmp: QMPClient? { get async { await session.qmp } }
}

/// A capability this backend does not have (yet).
public struct BackendUnsupported: Error, Equatable, Sendable, CustomStringConvertible {
    public let feature: String
    public var description: String { "\(feature) is not available for this VM" }
}

/// The running VM's processes and QMP connection. One start at a time; everything on this actor.
actor QEMUSession {
    private static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "qemu")

    private struct Running {
        let qemu: ProcessRecord
        let swtpm: ProcessRecord?
        let qmp: QMPClient
        let layout: QEMULayout
    }

    private var config: VMConfigV1
    private var processes: QEMUProcesses
    private let resolveInstallation: @Sendable () throws -> QEMUInstallation
    private let events: AsyncStream<BackendEvent>.Continuation
    private var running: Running?
    /// Why QEMU is about to exit (a stop request, the guest powering off); nil means unexpected.
    private var exitReason: String?
    /// Set when the VM must be reported as failed when QEMU exits (e.g. the TPM went away).
    private var failure: String?
    private var displaySize: (width: Int, height: Int)?
    private var pressedButtons = 0

    init(
        config: VMConfigV1, processes: QEMUProcesses, resolveInstallation: @escaping @Sendable () throws -> QEMUInstallation,
        events: AsyncStream<BackendEvent>.Continuation
    ) {
        self.config = config
        self.processes = processes
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
            }
        }
    }

    /// QMP events → backend events.
    private func watch(_ qmp: QMPClient) {
        Task {
            for await event in qmp.events {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: QMPEvent) {
        switch event.name {
        case "STOP": events.yield(.paused)
        case "RESUME": events.yield(.resumed)
        case "SHUTDOWN":
            // QEMU exits next; the guest powering off is a normal stop.
            if exitReason == nil {
                exitReason =
                    event.data["guest"] == true ? "guest powered off" : "QEMU shut down (\(event.data["reason"]?.stringValue ?? "unknown"))"
            }
        case "GUEST_PANICKED":
            Self.log.error("guest panicked: \(String(describing: event.data), privacy: .public)")
            events.yield(.failed(message: "Windows stopped with an error (guest panic). Restart the VM; the logs have details."))
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
    private func swtpmExited(_ exit: ChildExit, swtpm: ProcessRecord) async {
        guard let current = running, current.swtpm == swtpm, exitReason == nil else { return }
        failure = "The VM's TPM emulator stopped (\(exit)); the VM was powered off to protect its TPM state."
        exitReason = "TPM emulator stopped"
        if (try? await current.qmp.execute("quit")) == nil { current.qemu.terminate() }
    }

    func execute(_ command: String, _ arguments: [String: JSONValue]? = nil) async throws {
        guard let qmp = running?.qmp else { throw QEMUBackendError.notRunning }
        try await qmp.execute(command, arguments)
    }

    func stop(_ mode: StopMode) async throws {
        guard let current = running else { throw QEMUBackendError.notRunning }
        switch mode {
        case .graceful:
            // ACPI power button: Windows shuts down (can take a minute); QEMU then exits by itself.
            try await current.qmp.execute("system_powerdown")
        case .force:
            exitReason = exitReason ?? "forced off"
            if (try? await current.qmp.execute("quit")) == nil {
                _ = await Blocking.run { current.qemu.terminate() }
            }
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
        do {
            if try await current.qmp.execute("query-status")["running"] == true { try await current.qmp.execute("stop") }
            try await QEMUState.save(current.qmp, to: partial, memoryMiB: config.memory.mib)
            try FileManager.default.moveItem(at: partial, to: final)
            try DurableWrite.syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            _ = try? await current.qmp.execute("cont")
            throw error
        }
        exitReason = "suspended"
        _ = try? await current.qmp.execute("quit")
        // Done only once QEMU and swtpm are gone: the state files must not change after this returns.
        let deadline = ContinuousClock.now + .seconds(30)
        while running?.qemu == current.qemu, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    func screenshot(maxEdge: Int) async throws -> Screenshot {
        let pixels = try await capture()
        guard let image = QEMUScreenshot.image(pixels), let shot = ScreenshotEncoder.png(image, maxEdge: maxEdge) else {
            throw QEMUScreenshotError.invalidImage("encoding")
        }
        return shot
    }

    /// `screendump` into the run directory, read back (no symlinks, size capped) and deleted.
    func capture() async throws -> QEMUScreenshot.Pixels {
        guard let current = running else { throw QEMUBackendError.notRunning }
        let file = current.layout.runDirectory.appendingPathComponent("shot-\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: file) }
        try await current.qmp.execute("screendump", ["filename": .string(file.path)], timeout: .seconds(10))
        let pixels = try QEMUScreenshot.decodePPM(
            try Self.readCapped(file, limit: QEMUScreenshot.maxDimension * QEMUScreenshot.maxDimension * 3 + 64))
        displaySize = (pixels.width, pixels.height)
        return pixels
    }

    func send(_ input: InputEvent) async throws {
        guard let current = running else { throw QEMUBackendError.notRunning }
        if case .pointer = input, displaySize == nil { _ = try await capture() }  // pointer coordinates need the display size
        let size = displaySize ?? (config.display.widthPx, config.display.heightPx)
        for step in try QEMUInput.steps(for: input, display: size, pressed: &pressedButtons) {
            switch step {
            case .command(let command, let arguments): try await current.qmp.execute(command, arguments)
            case .pause(let duration): try await Task.sleep(for: duration)
            }
        }
    }

    private static func readCapped(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw QEMUScreenshotError.invalidImage("too large")
        }
        return data
    }
}

extension QEMUProcesses {
    /// The installation chosen for this start (the layout's paths follow it).
    mutating func layoutInstallation(_ installation: QEMUInstallation) {
        layout = QEMULayout(bundle: layout.bundle, runDirectory: layout.runDirectory, installation: installation)
    }
}
