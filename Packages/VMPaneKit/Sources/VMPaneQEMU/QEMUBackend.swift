import Foundation
import VMPaneCore

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
    /// QEMU's SPICE socket (`run/<sid>/spice.sock`), for the helper's display.
    public let displaySocket: URL

    /// When the guest is paused for a full disk: below `pauseBelow` free bytes on the bundle's volume, and it
    /// resumes only from `resumeFrom`. The NVMe device has no error policy, so a write into a full volume
    /// would fail inside Windows; the watchdog keeps it from getting there.
    public struct SpacePolicy: Sendable {
        public var pauseBelow: UInt64
        public var resumeFrom: UInt64
        public var interval: Duration
        public var freeBytes: @Sendable (URL) throws -> UInt64

        public static let standard = SpacePolicy(
            pauseBelow: 2 << 30, resumeFrom: 3 << 30, interval: .seconds(1), freeBytes: SpaceGuard.freeBytes)

        public init(pauseBelow: UInt64, resumeFrom: UInt64, interval: Duration, freeBytes: @escaping @Sendable (URL) throws -> UInt64) {
            self.pauseBelow = pauseBelow
            self.resumeFrom = resumeFrom
            self.interval = interval
            self.freeBytes = freeBytes
        }
    }

    /// `resolveInstallation` picks and validates the QEMU to run at each start (`QEMUPaths.resolve`).
    public init(
        config: VMConfigV1, processes: QEMUProcesses, space: SpacePolicy = .standard,
        resolveInstallation: @escaping @Sendable () throws -> QEMUInstallation
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        events = stream
        displaySocket = processes.layout.spiceSocket
        session = QEMUSession(
            config: config, processes: processes, space: space, resolveInstallation: resolveInstallation, events: continuation)
    }

    public func start(_ options: StartOptions) async throws { try await session.start(options) }
    public func pause() async throws { try await session.execute("stop") }
    public func resume() async throws { try await session.resume() }

    public func suspend(to stateDirectory: URL) async throws { try await session.suspend(to: stateDirectory) }
    public func saveState(to stateDirectory: URL) async throws { try await session.saveState(to: stateDirectory) }

    public func stop(_ mode: StopMode) async throws { try await session.stop(mode) }

    /// Runs before every quit of QEMU (the helper disconnects its SPICE client).
    public func setBeforeQuit(_ hook: @escaping @Sendable () async -> Void) async { await session.setBeforeQuit(hook) }
    public func screenshot(maxEdge: Int) async throws -> Screenshot { try await session.screenshot(maxEdge: maxEdge) }

    /// Live: port forwards (slirp `hostfwd_add`/`hostfwd_remove`). Everything else takes effect at the next start.
    public func applyLive(_ config: VMConfigV1, paths: [String]) async -> Set<String> {
        await session.applyLive(config, paths: paths)
    }
    public func send(_ input: InputEvent) async throws { try await session.send(input) }

    /// QMP for integration hooks and later features (snapshots, live settings).
    var qmp: QMPClient? { get async { await session.qmp } }
}

/// A capability this backend does not have (yet).
public struct BackendUnsupported: Error, Equatable, Sendable, CustomStringConvertible {
    public let feature: String
    public var description: String { "\(feature) is not available for this VM" }
}

extension QEMUProcesses {
    /// The installation chosen for this start (the layout's paths follow it).
    mutating func layoutInstallation(_ installation: QEMUInstallation) {
        layout = QEMULayout(bundle: layout.bundle, runDirectory: layout.runDirectory, installation: installation)
    }
}
