import Foundation
import Observation
import VMPaneControl
import VMPaneCore

/// A control connection the VM window uses (`UDSClient` to its own helper; faked in tests).
public protocol HelperChannel: Sendable {
    func call(_ method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue
    var notifications: AsyncStream<RPCRequest> { get }
}

extension UDSClient: HelperChannel {}

/// What the VM window shows and does: the VM's state, an install in progress, whether the guest agent is
/// there, and the toolbar's actions. It talks to its own helper through the control socket like any client, so
/// the window sees exactly what the CLI and the app see.
@MainActor
@Observable
public final class HelperViewModel {
    public struct InstallProgress: Equatable, Sendable {
        public var phase: String
        public var percent: Int
        public var message: String

        /// Still going (not done, failed or cancelled).
        public var isActive: Bool { !["done", "failed", "cancelled"].contains(phase) && percent < 100 }
    }

    public private(set) var state: VMRunState = .stopped
    /// The VM's name (from `vm.info`): the window's title, which follows a rename.
    public private(set) var name: String?
    /// Stopped with its RAM state saved: a start resumes it.
    public private(set) var suspended = false
    public private(set) var allowed: Set<String> = []
    public private(set) var install: InstallProgress?
    /// The guest system (from `vm.info`); names what an install overlay installs.
    public private(set) var os: GuestOS?
    public private(set) var agentConnected = false
    /// The last failed action, for an alert.
    public var lastError: String?
    /// The last screenshot saved, for a confirmation.
    public private(set) var lastScreenshot: URL?
    /// A short confirmation the window shows for a moment ("Snapshot taken"); nil when there is none.
    public var notice: String?
    /// For the one-time hints (`accessibilityHintShown.<id>`).
    private var vmID: String?
    public static let accessibilityHint =
        "An AI agent asked for this VM's controls: in the VM, allow vmpane-agent in System Settings › Privacy & Security › Accessibility"
    /// A snapshot is being taken (its button waits).
    public private(set) var takingSnapshot = false
    /// The VM's sound settings, for the toolbar's indicators.
    public private(set) var audioOutput = false
    public private(set) var audioInput = false
    /// The Mac's default input device is in use (checked while the microphone is passed to a running VM).
    public private(set) var inputInUse = false
    /// Files being copied into the guest (dropped on the window), with progress; nil when none.
    public internal(set) var transfer: Transfer?
    /// The Mac is nearly out of memory while the VM runs (`watchMemory`).
    public private(set) var memoryLow = false
    /// Asks before a start on a Mac low on memory, and reads the Mac's memory for `memoryLow`; nil: neither.
    @ObservationIgnored public var lowMemoryGuard: LowMemoryGuard?

    public struct Transfer: Equatable, Sendable {
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var file: String

        public var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
    }

    @ObservationIgnored let channel: HelperChannel
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(channel: HelperChannel) {
        self.channel = channel
    }

    /// Subscribes to the helper's events and reads its current state.
    public func start() async {
        do {
            _ = try await channel.call(
                ControlMethod.eventsSubscribe.rawValue, params: ["topics": ["vm", "install", "agent", "files"]], timeout: .seconds(5))
            await refresh()
            await refreshAudio()
            agentConnected =
                (try? await channel.call(ControlMethod.agentStatus.rawValue, params: nil, timeout: .seconds(5)))?["connected"] == true
        } catch {
            lastError = String(describing: error)
        }
        let notifications = channel.notifications
        listener = Task { [weak self] in
            for await note in notifications { self?.apply(note) }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    func refresh() async {
        guard let info = try? await channel.call(ControlMethod.vmInfo.rawValue, params: nil, timeout: .seconds(5)) else { return }
        if let state = info["state"]?.stringValue.flatMap(VMRunState.init(rawValue:)) { self.state = state }
        if let os = info["os"]?.stringValue.flatMap(GuestOS.init(rawValue:)) { self.os = os }
        if let name = info["name"]?.stringValue { self.name = name }
        if let id = info["id"]?.stringValue { vmID = id }
        suspended = info["suspended"] == true
        if case .array(let names)? = info["allowedRequests"] { allowed = Set(names.compactMap(\.stringValue)) }
    }

    /// Reads the sound settings (after a start, they are what the VM runs with).
    func refreshAudio() async {
        guard let config = try? await channel.call(ControlMethod.vmSettingsGet.rawValue, params: nil, timeout: .seconds(5)) else { return }
        audioOutput = config["audio"]?["output"] == true
        audioInput = config["audio"]?["input"] == true
    }

    /// Follows the input device while the VM runs with the microphone (every 2 s; CoreAudio's own notification
    /// would need a listener per device).
    public func watchInput() async {
        while !Task.isCancelled {
            let watching = audioInput && state == .running
            inputInUse = watching && MicrophoneActivity.defaultInputInUse()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Follows the Mac's memory while the VM runs or is paused: `memoryLow` once the Mac is nearly out, until it has
    /// room again.
    public func watchMemory(every interval: Duration = .seconds(5)) async {
        guard let read = lowMemoryGuard?.memory else { return }
        while !Task.isCancelled {
            if state == .running || state == .paused {
                if let host = read() {
                    if host.nearlyOut { memoryLow = true } else if host.recovered { memoryLow = false }
                }
            } else {
                memoryLow = false
            }
            try? await Task.sleep(for: interval)
        }
    }

    func apply(_ note: RPCRequest) {
        switch note.method {
        case ControlNotification.vmStateChanged.rawValue:
            if let state = note.params?["state"]?.stringValue.flatMap(VMRunState.init(rawValue:)) {
                self.state = state
                Task {
                    await refresh()
                    if state == .running { await refreshAudio() }
                }
            }
        case ControlNotification.installProgress.rawValue:
            install = InstallProgress(
                phase: note.params?["phase"]?.stringValue ?? "install",
                percent: Int(note.params?["percent"]?.intValue ?? 0),
                message: note.params?["message"]?.stringValue ?? "")
        case ControlNotification.agentConnectionChanged.rawValue:
            agentConnected = note.params?["connected"] == true
        case ControlNotification.screenAccessibilityNeeded.rawValue:
            // Once per VM: macOS shows its own prompt in the guest too.
            let key = "accessibilityHintShown.\(vmID ?? "?")"
            guard !UserDefaults.standard.bool(forKey: key) else { break }
            UserDefaults.standard.set(true, forKey: key)
            notice = Self.accessibilityHint
        case ControlNotification.filesProgress.rawValue where transfer != nil:
            transfer = Transfer(
                bytesDone: note.params?["bytesDone"]?.intValue ?? 0, bytesTotal: note.params?["bytesTotal"]?.intValue ?? 0,
                file: note.params?["file"]?.stringValue ?? "")
        default:
            break
        }
    }

    // MARK: - Actions

    public enum Action: Sendable {
        case start, shutDown, forceStop, pause, resume, suspend, snapshot
    }

    /// Whether `action` makes sense now (the helper's allowed requests).
    public func can(_ action: Action) -> Bool {
        switch action {
        case .start: allowed.contains("start")
        case .shutDown, .forceStop: allowed.contains("stop")
        case .pause: allowed.contains("pause")
        case .resume: allowed.contains("resume")
        case .suspend: allowed.contains("suspend")
        case .snapshot: (state == .running || state == .paused) && !takingSnapshot
        }
    }

    public func perform(_ action: Action) async {
        let (method, params): (ControlMethod, JSONValue?) =
            switch action {
            case .start: (.vmStart, ["headless": false])
            case .shutDown: (.vmStop, ["mode": "graceful"])
            case .forceStop: (.vmStop, ["mode": "force"])
            case .pause: (.vmPause, nil)
            case .resume: (.vmResume, nil)
            case .suspend: (.vmSuspend, nil)
            case .snapshot: (.vmSnapshotCreate, ["name": .string(Self.snapshotName()), "kind": "live"])
            }
        if action == .start, let lowMemoryGuard, !(await hasMemoryToStart(lowMemoryGuard)) { return }
        if action == .snapshot { takingSnapshot = true }
        defer { if action == .snapshot { takingSnapshot = false } }
        do {
            _ = try await channel.call(method.rawValue, params: params, timeout: .seconds(120))
            if action == .snapshot { notice = "Snapshot taken" }
        } catch let error as RPCError {
            lastError = error.message
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Whether to start: the VM's memory (its settings now) fits in what the Mac has, or the person said to go ahead.
    private func hasMemoryToStart(_ lowMemoryGuard: LowMemoryGuard) async -> Bool {
        let config = try? await channel.call(ControlMethod.vmSettingsGet.rawValue, params: nil, timeout: .seconds(5))
        guard let mib = config?["memory"]?["mib"]?.intValue else { return true }
        return await lowMemoryGuard.allows(name: name ?? "This VM", guestMiB: Int(mib))
    }

    /// Ends the Windows install as cancelled; the helper stops the VM.
    public func cancelInstall() async {
        do {
            _ = try await channel.call(ControlMethod.vmInstallCancel.rawValue, params: nil, timeout: .seconds(30))
        } catch let error as RPCError {
            lastError = error.message
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Saves a PNG of the guest display to `directory` (the Desktop, like macOS screenshots).
    public func screenshot(to directory: URL) async {
        do {
            let result = try await channel.call(ControlMethod.vmScreenshot.rawValue, params: ["maxEdge": 8192], timeout: .seconds(10))
            guard let base64 = result["dataB64"]?.stringValue, let png = Data(base64Encoded: base64) else {
                throw RPCError(.internalError, "the helper sent no image")
            }
            let url = directory.appendingPathComponent("VM Screenshot \(Self.stamp()).png")
            try png.write(to: url)
            lastScreenshot = url
            notice = "Screenshot saved to the Desktop"
        } catch let error as RPCError {
            lastError = error.message
        } catch {
            lastError = String(describing: error)
        }
    }

    public func snapshotsModel() -> SnapshotsModel { SnapshotsModel(channel: channel) }

    /// The settings sheet's model, with the helper's current config.
    public func loadSettings() async -> SettingsModel? {
        do {
            return try await SettingsModel.load(channel)
        } catch {
            lastError = "Cannot read the settings: \(error)"
            return nil
        }
    }

    public static func snapshotName(now: Date = Date()) -> String { "Snapshot \(stamp(now))" }

    static func stamp(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: now)
    }
}
