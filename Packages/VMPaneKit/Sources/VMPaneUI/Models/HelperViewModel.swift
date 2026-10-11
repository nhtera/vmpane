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
    public private(set) var allowed: Set<String> = []
    public private(set) var install: InstallProgress?
    public private(set) var agentConnected = false
    /// The last failed action, for an alert.
    public var lastError: String?
    /// The last screenshot saved, for a confirmation.
    public private(set) var lastScreenshot: URL?
    /// Files being copied into the guest (dropped on the window), with progress; nil when none.
    public internal(set) var transfer: Transfer?

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

    private func refresh() async {
        guard let info = try? await channel.call(ControlMethod.vmInfo.rawValue, params: nil, timeout: .seconds(5)) else { return }
        if let state = info["state"]?.stringValue.flatMap(VMRunState.init(rawValue:)) { self.state = state }
        if case .array(let names)? = info["allowedRequests"] { allowed = Set(names.compactMap(\.stringValue)) }
    }

    func apply(_ note: RPCRequest) {
        switch note.method {
        case ControlNotification.vmStateChanged.rawValue:
            if let state = note.params?["state"]?.stringValue.flatMap(VMRunState.init(rawValue:)) {
                self.state = state
                Task { await refresh() }
            }
        case ControlNotification.installProgress.rawValue:
            install = InstallProgress(
                phase: note.params?["phase"]?.stringValue ?? "install",
                percent: Int(note.params?["percent"]?.intValue ?? 0),
                message: note.params?["message"]?.stringValue ?? "")
        case ControlNotification.agentConnectionChanged.rawValue:
            agentConnected = note.params?["connected"] == true
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
        case .snapshot: state == .running || state == .paused
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
        do {
            _ = try await channel.call(method.rawValue, params: params, timeout: .seconds(120))
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

    static func snapshotName(now: Date = Date()) -> String { "Snapshot \(stamp(now))" }

    static func stamp(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: now)
    }
}
