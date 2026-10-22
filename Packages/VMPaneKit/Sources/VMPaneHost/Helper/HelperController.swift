import CryptoKit
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
    private(set) var shuttingDown = false
    /// What the VM's last stop does to the bundle (the after-stop hook, an install's finalize or clean-up).
    var stopHandling: Task<Void, Never>?
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
    /// Who each control connection is (`HelperController+Policy`), the classifier that decides it, the policy key
    /// and the VM's audit log.
    var identities: [ObjectIdentifier: CallerIdentity] = [:]
    var classifier: PeerClassifier
    var policyKey: SymmetricKey?
    let auditLog: AuditLog
    /// The agent kill switch (`HelperController+KillSwitch`): its state, the watch on VMPane's folder, and a
    /// counter agents' transfers compare against to notice it.
    var killSwitchEngaged = false
    var killSwitchWatch: DispatchSourceFileSystemObject?
    var killSwitchPoll: Task<Void, Never>?
    var agentGeneration = 0
    /// Asks the person before an agent's command or admin action (`HelperController+Confirm`).
    var confirmationPresenter: (@Sendable (ConfirmationRequest) async -> Bool)?
    var confirmationDismiss: (@Sendable () async -> Void)?
    /// A question is on screen (they are asked one at a time).
    var confirming = false
    /// Agent sessions' undo snapshots being taken (concurrent first calls wait for the same one).
    var agentSnapshotTasks: [String: Task<SnapshotMeta?, Never>] = [:]
    /// A snapshot is being taken: the next one waits for it (VZ cannot save a VM's state twice at once).
    var snapshotting = false
    /// An input batch is running (`HelperController+InputBatch`): the next one waits for it.
    var batching = false
    /// The helper is signing the guest in (`HelperController+SignIn`): agents' input is refused meanwhile.
    var signingIn = false
    /// Single input requests being sent (`displayRequest`), which a sign-in waits for.
    var inputsInFlight = 0
    /// What agents did lately, and the person's Take over (`AgentActivity`).
    var activity = AgentActivityState()
    /// How long a question waits for the person (`HelperController+Confirm`); no answer is a no.
    var confirmationTimeout: Duration = .seconds(60)
    /// Agent sessions' undo snapshots (`HelperController+AgentSession`).
    var agentSessions: [String: AgentSession] = [:]
    /// The file drop in progress (`vm.files.cancel` stops it).
    var dropTask: Task<Result<JSONValue, RPCError>, Never>?
    /// The connection that started it (only it may cancel it).
    var dropOwner: ObjectIdentifier?
    /// A running VZ VM's port forwards (`HelperController+Ports`).
    var portForwarder: PortForwarder?
    /// The display as the helper app has it (a QEMU VM's SPICE session, in memory), read before the backend's
    /// (`HelperController+InputBatch`, screenshots).
    var displaySource: GuestDisplaySource?
    /// Refreshes `thumbnail.png` while the VM runs (`HelperController+Thumbnail`).
    var thumbnailTask: Task<Void, Never>?
    /// The config the running VM was started with, plus settings applied live since (nil before a start).
    var runningConfig: VMConfigV1?
    /// Whether the Mac is locked (replaced in tests).
    var isSessionLocked: @Sendable () -> Bool = SessionLock.isLocked
    /// Refuses RAM-state saves without room for them (replaced in tests, which must not depend on this Mac's disk).
    var checkSpace: @Sendable (_ memoryBytes: UInt64, _ at: URL) throws -> Void = { try SpaceGuard.check(memoryBytes: $0, at: $1) }
    /// How long `vm.start` waits on a macOS install before replying that it is under way (shorter in tests).
    var installReplyAfter: Duration = .seconds(15)
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
        classifier = PeerClassifier.current()
        auditLog = AuditLog(bundle: prepared.lock.bundle)
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
        startKillSwitch()
        startEventPump()
        startAgentPump()
    }

    /// Stops the server, stops recorded children, removes run files and releases the bundle lock.
    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        await stopBackendForShutdown()  // the VM must be down before its disks' lock is released
        await stopHandling?.value  // its writes to the bundle too
        pumpTask?.cancel()
        stopKillSwitchWatch()
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

    /// Every request: who sent it decides whether the VM's agent policy allows it (`HelperController+Policy`).
    func handle(_ request: RPCRequest, from connection: ControlConnection) async -> Result<JSONValue, RPCError> {
        if request.method == ControlMethod.helperHello.rawValue { noteHello(request.params, from: connection) }
        let caller = identity(of: connection)
        let started = ContinuousClock.now
        if let denial = authorize(request, caller) { return .failure(denial) }
        if let held = heldForSignIn(ControlMethod(rawValue: request.method), connection) { return .failure(held) }
        if let refusal = await agentChecks(request, caller) {
            audit(request, caller, result: .failure(refusal), since: started)
            return .failure(refusal)
        }
        let result = await route(request, from: connection)
        if caller.identity != .ui { audit(request, caller, result: result, since: started) }
        return result
    }

    func route(_ request: RPCRequest, from connection: ControlConnection) async -> Result<JSONValue, RPCError> {
        switch ControlMethod(rawValue: request.method) {
        case .helperHello?: return hello(request.params)
        case .helperShutdown?:
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))  // let the response go out first
                await self?.shutdown()
            }
            return .success(.object([:]))
        case .vmInfo?: return info()
        case .vmScreenshot?, .vmScreenRead?, .vmInputKey?, .vmInputText?, .vmInputPointer?, .vmInputScroll?:
            return await displayRequest(request.method, request.params, from: connection)
        case .vmInputBatch?: return await inputBatch(request.params, from: connection)
        case .vmSignIn?: return await signIn(from: connection)
        case .vmAgentActivity?, .vmAgentTakeOver?, .vmAgentResume?, .vmAgentStop?: return await agentActivityRequest(request.method)
        case .vmDisplayShow?:
            displayContinuation.yield()
            return .success(.object([:]))
        case .vmInstallCancel?: return await cancelInstall()
        case .agentStatus?, .agentExec?, .agentExecInput?, .agentExecSignal?, .agentFilePush?, .agentFilePull?:
            return await agentRequest(request.method, request.params, from: connection)
        case .eventsSubscribe?: return subscribe(request.params, connection)
        case .vmSettingsGet?: return RPCParams.encode(config)
        case .vmPortsList?: return await portsList()
        case .vmFilesDrop?, .vmFilesCancel?: return await filesRequest(request, from: connection)
        case .mcpDisableAll?: return await killSwitchRequest(engage: true)
        case .mcpEnableAll?: return await killSwitchRequest(engage: false)
        case .vmClipboardRead?: return await clipboardRead(request.params, from: connection)
        case .vmClipboardWrite?: return await clipboardWrite(request.params, from: connection)
        case .vmSettingsApply?: return await applySettings(request.params, byApp: identity(of: connection).identity == .ui)
        case .vmStart?, .vmPause?, .vmResume?, .vmSuspend?, .vmStop?:
            return await lifecycle(request.method, request.params)
        case .vmSnapshotList?, .vmSnapshotCreate?, .vmSnapshotDelete?, .vmSnapshotRestore?, .vmSnapshotRename?:
            return await snapshotRequest(request.method, request.params, byApp: identity(of: connection).identity == .ui)
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
        let policy = effectivePolicy()
        return .success([
            "id": .string(config.id.uuidString), "name": .string(config.name), "os": .string(config.os.rawValue),
            "backend": .string(config.backend.rawValue), "state": .string(state.rawValue),
            "allowedRequests": .array(backend == nil ? [] : HelperStateMachine.allowedRequests(in: state).map { .string($0.rawValue) }),
            "capabilities": .array(capabilities.map { .string($0) }),
            "pendingRestart": .bool(pendingRestart),
            "suspended": .bool(state == .stopped && prepared.lock.bundle.isSuspended),
            // The agent level in effect, and whether a raised level was set outside VMPane (and so counts as off).
            "policy": .string(policy.level.rawValue), "policyTampered": .bool(policy.tampered),
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

    /// `events.subscribe` is observe; the serial console's output (whatever the guest prints there, which can be
    /// what is typed at it) needs control for an agent.
    private func subscribe(_ params: JSONValue?, _ connection: ControlConnection) -> Result<JSONValue, RPCError> {
        RPCParams.decode(SubscribeParams.self, from: params).flatMap { params in
            if params.topics.contains("console"), identity(of: connection).identity == .automated, effectivePolicy().level < .control {
                return .failure(
                    RPCError(
                        .policyDenied, "the console topic needs policy level control; this VM allows \(effectivePolicy().level.rawValue)"))
            }
            connection.subscribe(Set(params.topics))
            // A window opened during an install shows it (and can cancel it) without waiting for the next phase.
            if params.topics.contains("install"), let progress = currentInstallProgress() {
                connection.notify(topic: "install", method: ControlNotification.installProgress.rawValue, params: progress)
            }
            return .success(.object([:]))
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

/// What tests and the helper app replace.
extension HelperController {
    public func setGracefulStopTimeout(_ timeout: Duration) { gracefulStopTimeout = timeout }
    func setConfirmationTimeout(_ timeout: Duration) { confirmationTimeout = timeout }
    func setSessionLockCheck(_ check: @escaping @Sendable () -> Bool) { isSessionLocked = check }
    func setClassifier(_ classifier: PeerClassifier) {
        self.classifier = classifier
        identities = [:]  // decided again with it
    }
    func setSpaceCheck(_ check: @escaping @Sendable (UInt64, URL) throws -> Void) { checkSpace = check }
}
