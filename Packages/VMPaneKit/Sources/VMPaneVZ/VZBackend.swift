import Foundation
import VMPaneCore
import Virtualization

/// `VMBackend` on Virtualization.framework (Linux guests now; macOS guests follow).
public final class VZBackend: VMBackend {
    public let kind = BackendKind.vz
    public let capabilities: LiveCapabilities = [.pause, .suspend, .liveSnapshot]
    public nonisolated let events: AsyncStream<BackendEvent>

    /// Saved RAM state inside the state directory (see `SavedStateRule`).
    public static let stateFileName = "suspend.vzvmsave"

    private let plan: VZPlan
    private let runner = VZRunner()
    private let serialLog: FileHandle?
    private let box = BoxHolder()

    public init(plan: VZPlan) {
        self.plan = plan
        events = runner.events
        serialLog = Self.openLog(plan.serialLog)
    }

    /// The VM for the display view, once started.
    public var virtualMachineBox: VMBox? { box.value }

    public func start(_ options: StartOptions) async throws {
        box.value = try await runner.create(plan, serialLog: serialLog)
        if let directory = options.stateDirectory {
            try await runner.restore(from: directory.appendingPathComponent(Self.stateFileName))
        } else {
            try await runner.start()
        }
    }

    public func pause() async throws { try await runner.pause() }
    public func resume() async throws { try await runner.resume() }

    /// Pause, save to `suspend.vzvmsave.partial`, rename, power off. On any failure the VM is resumed.
    public func suspend(to stateDirectory: URL) async throws {
        let final = stateDirectory.appendingPathComponent(Self.stateFileName)
        let partial = stateDirectory.appendingPathComponent(Self.stateFileName + ".partial")
        if try await runner.state == .running { try await runner.pause() }
        do {
            try await runner.save(to: partial)
            try FileManager.default.moveItem(at: partial, to: final)
            try DurableWrite.syncDirectory(stateDirectory)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            try? await runner.resume()
            throw error
        }
        try await runner.forceStop(reason: "suspended")
    }

    public func saveState(to stateDirectory: URL) async throws {
        try await runner.save(to: stateDirectory.appendingPathComponent(Self.stateFileName))
    }

    public func stop(_ mode: StopMode) async throws {
        switch mode {
        case .graceful: try await runner.requestStop()
        case .force: try await runner.forceStop(reason: "forced off")
        }
    }

    public func screenshot(maxEdge: Int) async throws -> Data {
        throw VZBackendError.notAvailableYet("screenshot")
    }

    public func send(_ input: InputEvent) async throws {
        throw VZBackendError.notAvailableYet("input")
    }

    /// Fills in what a VZ guest needs before its first start (a persisted machine identifier).
    /// Returns nil when nothing changed.
    public static func prepare(_ config: VMConfigV1) -> VMConfigV1? {
        guard config.os == .linux, config.platform.machineIdentifier == nil else { return nil }
        var config = config
        config.platform.machineIdentifier = VZMaterializer.newMachineIdentifier()
        return config
    }

    private static func openLog(_ url: URL) -> FileHandle? {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    private final class BoxHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var box: VMBox?
        var value: VMBox? {
            get { lock.withLock { box } }
            set { lock.withLock { box = newValue } }
        }
    }
}

public enum VZBackendError: Error, Equatable, Sendable {
    case notAvailableYet(String)
}

extension VZBackend {
    /// `VZVirtualMachineConfiguration.validate()` for this plan. Needs the virtualization entitlement.
    public static func validate(_ plan: VZPlan) throws {
        try VZMaterializer.configuration(plan, serialLog: nil).validate()
    }
}
