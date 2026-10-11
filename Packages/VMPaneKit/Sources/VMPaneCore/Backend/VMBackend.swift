import Foundation

/// Run state of a VM as reported by its helper.
public enum VMRunState: String, Codable, Sendable, CaseIterable {
    case stopped, starting, running, paused, suspending, stopping, error
}

public enum StopMode: String, Codable, Sendable {
    /// ACPI power button: the guest shuts down cleanly.
    case graceful
    /// Immediate power-off (risks guest file systems; Windows may run repair on next boot).
    case force
}

public struct StartOptions: Sendable, Equatable {
    public var headless: Bool
    /// Saved RAM state to resume from (already checked by `SavedStateRule`), or nil for a cold boot.
    public var stateDirectory: URL?
    /// The saved config to start with: backends rebuild their devices from it, so settings saved for the
    /// next boot take effect. Nil keeps the backend's last config.
    public var config: VMConfigV1?

    public init(headless: Bool, stateDirectory: URL? = nil, config: VMConfigV1? = nil) {
        self.headless = headless
        self.stateDirectory = stateDirectory
        self.config = config
    }
}

/// Saved RAM state exists but cannot be read now (VZ: the Mac is locked); it must be kept, not discarded.
public struct SavedStateLocked: Error, Sendable, Equatable {
    public init() {}
}

/// What a backend can do while the VM runs.
public struct LiveCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let pause = LiveCapabilities(rawValue: 1 << 0)
    public static let suspend = LiveCapabilities(rawValue: 1 << 1)
    public static let liveSnapshot = LiveCapabilities(rawValue: 1 << 2)
    public static let screenshot = LiveCapabilities(rawValue: 1 << 3)
    public static let resize = LiveCapabilities(rawValue: 1 << 4)
    public static let input = LiveCapabilities(rawValue: 1 << 5)
    public static let hotplugRemovable = LiveCapabilities(rawValue: 1 << 6)
}

/// Synthetic input, in guest display coordinates for pointers.
public enum InputEvent: Sendable, Equatable, Codable {
    /// USB HID usage (keyboard page) with up/down.
    case key(usage: UInt16, down: Bool)
    case text(String)
    case pointer(x: Double, y: Double, buttons: Int)
    case scroll(dx: Double, dy: Double)
}

/// A captured guest display.
public struct Screenshot: Sendable, Equatable {
    public let png: Data
    public let width: Int
    public let height: Int

    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }
}

/// Events a backend reports to its helper.
public enum BackendEvent: Sendable, Equatable {
    case started
    case paused
    case resumed
    /// RAM state was written to the state directory.
    case suspended
    /// The guest powered off (by itself or after a stop request).
    case stopped(reason: String)
    case failed(message: String)
    /// The backend paused the guest because the volume holding its disks is (nearly) full; it resumes once
    /// space has been freed (writes into a full volume would fail inside the guest).
    case diskFull(message: String)
    case consoleOutput(Data)
    /// OS installation progress (0…1) while starting a VM that is not installed yet.
    case installProgress(fraction: Double, message: String)
    /// The guest restarted itself (a reboot inside the guest; the VM keeps running).
    case guestReset
}

/// A hypervisor backend driving one VM (Virtualization.framework or QEMU).
public protocol VMBackend: AnyObject, Sendable {
    var kind: BackendKind { get }
    var capabilities: LiveCapabilities { get }
    var events: AsyncStream<BackendEvent> { get }

    func start(_ options: StartOptions) async throws
    func pause() async throws
    func resume() async throws
    /// Saves RAM state into `stateDirectory` (`*.partial`, renamed when complete) and stops. If it
    /// throws, the VM must be running again (resumed), never left paused.
    func suspend(to stateDirectory: URL) async throws
    /// Saves RAM state of the *paused* VM into `stateDirectory` (for live snapshots); the VM stays paused.
    func saveState(to stateDirectory: URL) async throws
    func stop(_ mode: StopMode) async throws
    /// PNG of the guest display, longest edge at most `maxEdge`.
    func screenshot(maxEdge: Int) async throws -> Screenshot
    func send(_ input: InputEvent) async throws
    /// Applies the settings at `paths` (`SettingKind.live`) of the saved `config` to the running VM.
    /// Returns the paths now in effect; the others take effect at the next start.
    func applyLive(_ config: VMConfigV1, paths: [String]) async -> Set<String>
    /// Removes the medium of the `removable` entry `id` from the running VM (the drive stays, empty).
    func ejectMedia(_ id: String) async throws
    /// Connections the guest agent opened to the host (vsock on VZ): connected stream sockets the receiver
    /// owns. Single consumer, for the backend's lifetime. Backends whose agent channel the helper opens itself
    /// (QEMU's chardev socket) yield nothing.
    var agentSockets: AsyncStream<Int32> { get }
}

extension VMBackend {
    public var agentSockets: AsyncStream<Int32> { AsyncStream { $0.finish() } }
    public func applyLive(_ config: VMConfigV1, paths: [String]) async -> Set<String> { [] }
    public func ejectMedia(_ id: String) async throws { throw BackendUnsupported(feature: "ejecting media") }
}

/// A capability a backend does not have (yet).
public struct BackendUnsupported: Error, Equatable, Sendable, CustomStringConvertible {
    public let feature: String
    public var description: String { "\(feature) is not available for this VM" }

}
