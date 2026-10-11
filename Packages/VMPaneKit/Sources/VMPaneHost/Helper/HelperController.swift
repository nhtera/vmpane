import Foundation
import VMPaneControl
import VMPaneCore

/// The per-VM helper: owns the bundle lock, the run files, the control socket and (from Phase 03/05)
/// the backend. One instance per helper process.
public actor HelperController {
    public let prepared: PreparedBundle
    public let runtimeVersion: String
    var config: VMConfigV1
    var state: VMRunState = .stopped
    let backend: VMBackend?
    var server: UDSServer?
    private let onShutdown: @Sendable () -> Void
    private var shuttingDown = false
    var pumpTask: Task<Void, Never>?
    /// How long shutdown waits for a guest to power off after the ACPI request before forcing it off.
    /// Windows takes 36–120 s (S2), and forcing it off risks Automatic Repair on the next boot.
    var gracefulStopTimeout: Duration
    /// Whether the VM was last started without a window (restarts after a restore keep it).
    var lastStartHeadless = true
    /// Whether the last start asked for no window (`vm.start {headless}`), for the helper's window logic.
    public var startedHeadless: Bool { lastStartHeadless }
    /// The unattended Windows install this VM is going through, if any (`HelperController+WindowsInstall`).
    var windowsInstall: InstallState?
    var installReader: GuestLineReader?
    var installWatch: Task<Void, Never>?
    var installTiming = InstallTiming()
    /// The guest agent's connection (`HelperController+Agent`).
    let agentHub = AgentHub(hostVersion: VMPane.version)
    let agentExecs = AgentExecs()
    var agentLink: UDSAgentLink?
    var agentTasks: [Task<Void, Never>] = []
    /// Clipboard sharing through the guest agent (`HelperController+Clipboard`), and the Mac's pasteboard the
    /// helper app provides for it.
    var clipboardBridge: ClipboardBridge?
    var hostPasteboard: HostPasteboard?
    /// Whether the VM's window is the key window now (kept for a bridge made later).
    var windowFocused = false
    /// A running Windows VM's shared folders over WebDAV (`HelperController+Shares`), and the drive mapping task.
    var webdav: SharesWebDAV?
    var webdavMapping: Task<Void, Never>?
    /// The file drop in progress (`vm.files.cancel` stops it).
    var dropTask: Task<Result<JSONValue, RPCError>, Never>?
    /// The connection that started it (only it may cancel it).
    var dropOwner: ObjectIdentifier?
    /// A running VZ VM's port forwards (`HelperController+Ports`).
    var portForwarder: PortForwarder?
    /// Refreshes `thumbnail.png` while the VM runs (`HelperController+Thumbnail`).
    var thumbnailTask: Task<Void, Never>?
    /// The config the running VM was started with, plus settings applied live since (nil before a start).
    var runningConfig: VMConfigV1?
    /// Whether the Mac is locked (replaced in tests).
    var isSessionLocked: @Sendable () -> Bool = SessionLock.isLocked
    /// Refuses RAM-state saves without room for them (replaced in tests, which must not depend on this Mac's disk).
    var checkSpace: @Sendable (_ memoryBytes: UInt64, _ at: URL) throws -> Void = { try SpaceGuard.check(memoryBytes: $0, at: $1) }
    let afterStart: (@Sendable (VMConfigV1) -> VMConfigV1?)?
    /// Config changes once the VM has stopped (e.g. detaching a finished Linux install's media).
    let afterStop: (@Sendable (VMConfigV1) -> VMConfigV1?)?
    /// The VM's configuration as the helper uses it now.
    public var currentConfig: VMConfigV1 { config }
    /// Every state the VM enters (the helper's window follows it). Single consumer.
    public nonisolated let stateChanges: AsyncStream<VMRunState>
    let stateContinuation: AsyncStream<VMRunState>.Continuation
    /// Asked to show the VM's window (`vm.display.show`).
    public nonisolated let displayRequests: AsyncStream<Void>
    let displayContinuation: AsyncStream<Void>.Continuation

    public func setGracefulStopTimeout(_ timeout: Duration) { gracefulStopTimeout = timeout }
    func setSessionLockCheck(_ check: @escaping @Sendable () -> Bool) { isSessionLocked = check }
    func setSpaceCheck(_ check: @escaping @Sendable (UInt64, URL) throws -> Void) { checkSpace = check }

    public init(
        prepared: PreparedBundle, runtimeVersion: String, backend: VMBackend?, config: VMConfigV1? = nil,
        afterStart: (@Sendable (VMConfigV1) -> VMConfigV1?)? = nil,
        afterStop: (@Sendable (VMConfigV1) -> VMConfigV1?)? = nil,
        onShutdown: @escaping @Sendable () -> Void
    ) {
        self.prepared = prepared
        self.runtimeVersion = runtimeVersion
        self.config = config ?? prepared.config
        self.afterStart = afterStart
        self.afterStop = afterStop
        (stateChanges, stateContinuation) = AsyncStream.makeStream(of: VMRunState.self)
        (displayRequests, displayContinuation) = AsyncStream.makeStream(of: Void.self)
        self.backend = backend
        gracefulStopTimeout = backend?.kind == .qemu ? .seconds(120) : .seconds(30)
        self.onShutdown = onShutdown
    }

    /// Binds `run/<sid>.sock` and starts answering requests.
    public func start() throws {
        let server = UDSServer(socketURL: prepared.runFiles.socketURL) { [weak self] request, connection in
            guard let self else { return .failure(RPCError(.internalError, "helper is shutting down")) }
            return await self.handle(request, from: connection)
        }
        try server.start()
        self.server = server
        startEventPump()
        startAgentPump()
    }

    /// Stops the server, stops recorded children, removes run files and releases the bundle lock.
    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        await stopBackendForShutdown()  // the VM must be down before its disks' lock is released
        pumpTask?.cancel()
        for task in agentTasks { task.cancel() }
        await agentLink?.stop()
        await agentHub.disconnect("the helper is shutting down")
        server?.stop()
        server = nil
        let prepared = prepared
        await Blocking.run {
            prepared.runFiles.reapChildren(of: prepared.owner)  // can wait seconds per child
            prepared.runFiles.removeAll()
            prepared.lock.release()
        }
        onShutdown()
    }

    // MARK: - Requests

    func handle(_ request: RPCRequest, from connection: ControlConnection) async -> Result<JSONValue, RPCError> {
        switch ControlMethod(rawValue: request.method) {
        case .helperHello?: return hello(request.params)
        case .helperShutdown?:
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))  // let the response go out first
                await self?.shutdown()
            }
            return .success(.object([:]))
        case .vmInfo?: return info()
        case .vmScreenshot?, .vmInputKey?, .vmInputText?, .vmInputPointer?, .vmInputScroll?:
            return await displayRequest(request.method, request.params)
        case .vmDisplayShow?:
            displayContinuation.yield()
            return .success(.object([:]))
        case .vmInstallCancel?: return await cancelInstall()
        case .agentStatus?, .agentExec?, .agentExecInput?, .agentExecSignal?, .agentFilePush?, .agentFilePull?:
            return await agentRequest(request.method, request.params, from: connection)
        case .eventsSubscribe?: return subscribe(request.params, connection)
        case .vmSettingsGet?: return RPCParams.encode(config)
        case .vmPortsList?: return await portsList()
        case .vmFilesDrop?:
            guard dropTask == nil else { return .failure(RPCError(.invalidState, "files are already being copied into the VM")) }
            let params = request.params
            let task = Task { await self.dropFiles(params) }
            dropTask = task
            dropOwner = ObjectIdentifier(connection)
            defer {
                dropTask = nil
                dropOwner = nil
            }
            return await task.value
        case .vmFilesCancel?:
            guard dropOwner == ObjectIdentifier(connection) else {
                return .failure(RPCError(.invalidState, "no file drop started by this connection"))
            }
            dropTask?.cancel()
            return .success([:])
        case .vmClipboardRead?: return await clipboardRead(request.params)
        case .vmClipboardWrite?: return await clipboardWrite(request.params)
        case .vmSettingsApply?: return await applySettings(request.params)
        case .vmStart?, .vmPause?, .vmResume?, .vmSuspend?, .vmStop?:
            return await lifecycle(request.method, request.params)
        case .vmSnapshotList?, .vmSnapshotCreate?, .vmSnapshotDelete?, .vmSnapshotRestore?:
            return await snapshotRequest(request.method, request.params)
        default:
            return .failure(RPCError(.methodNotFound, "\(request.method) is not available in this helper"))
        }
    }

    private struct HelloClient: Decodable {
        var name: String
        var version: String
        var kind: String
    }

    private struct HelloParams: Decodable {
        var proto: Int
        var minProto: Int
        var client: HelloClient
    }

    private func hello(_ params: JSONValue?) -> Result<JSONValue, RPCError> {
        RPCParams.decode(HelloParams.self, from: params).flatMap { hello in
            guard let proto = ControlProtocol.negotiate(peerVersion: hello.proto, peerMinimum: hello.minProto) else {
                return .failure(
                    RPCError(
                        .protoUnsupported, "no shared protocol version",
                        data: [
                            "proto": .int(Int64(ControlProtocol.version)),
                            "minProto": .int(Int64(ControlProtocol.minimumVersion)),
                        ]))
            }
            return .success([
                "proto": .int(Int64(proto)), "helperVersion": .string(VMPane.version),
                "runtimeVersion": .string(runtimeVersion),
            ])
        }
    }

    private func info() -> Result<JSONValue, RPCError> {
        let capabilities = backend.map { Self.names($0.capabilities) } ?? []
        return .success([
            "id": .string(config.id.uuidString), "name": .string(config.name), "os": .string(config.os.rawValue),
            "backend": .string(config.backend.rawValue), "state": .string(state.rawValue),
            "allowedRequests": .array(backend == nil ? [] : HelperStateMachine.allowedRequests(in: state).map { .string($0.rawValue) }),
            "capabilities": .array(capabilities.map { .string($0) }),
            "pendingRestart": .bool(pendingRestart),
        ])
    }

    /// Saved settings change hardware the running VM does not have yet: they need a restart, and a suspend
    /// now would be discarded at the next start (its state would not match the new hardware).
    var pendingRestart: Bool {
        guard [.running, .paused].contains(state), let runningConfig else { return false }
        return DeviceSet(runningConfig).hash != DeviceSet(config).hash
    }

    private static func names(_ capabilities: LiveCapabilities) -> [String] {
        let all: [(LiveCapabilities, String)] = [
            (.pause, "pause"), (.suspend, "suspend"), (.liveSnapshot, "liveSnapshot"),
            (.screenshot, "screenshot"), (.resize, "resize"), (.input, "input"),
            (.hotplugRemovable, "hotplugRemovable"),
        ]
        return all.filter { capabilities.contains($0.0) }.map(\.1)
    }

    private struct SubscribeParams: Decodable { var topics: [String] }

    private func subscribe(_ params: JSONValue?, _ connection: ControlConnection) -> Result<JSONValue, RPCError> {
        RPCParams.decode(SubscribeParams.self, from: params).map { params in
            connection.subscribe(Set(params.topics))
            return .object([:])
        }
    }

    static let hostBuild: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }()
}
