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

    public init(headless: Bool, stateDirectory: URL? = nil) {
        self.headless = headless
        self.stateDirectory = stateDirectory
    }
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
    case consoleOutput(Data)
}

/// A hypervisor backend driving one VM (Virtualization.framework or QEMU).
public protocol VMBackend: AnyObject, Sendable {
    var kind: BackendKind { get }
    var capabilities: LiveCapabilities { get }
    var events: AsyncStream<BackendEvent> { get }

    func start(_ options: StartOptions) async throws
    func pause() async throws
    func resume() async throws
    /// Saves RAM state into `stateDirectory` (`*.partial`, renamed when complete) and stops.
    func suspend(to stateDirectory: URL) async throws
    func stop(_ mode: StopMode) async throws
    /// PNG of the guest display, longest edge at most `maxEdge`.
    func screenshot(maxEdge: Int) async throws -> Data
    func send(_ input: InputEvent) async throws
}
