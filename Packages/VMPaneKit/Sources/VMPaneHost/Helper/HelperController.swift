import Foundation
import VMPaneControl
import VMPaneCore

/// The per-VM helper: owns the bundle lock, the run files, the control socket and (from Phase 03/05)
/// the backend. One instance per helper process.
public actor HelperController {
    public let prepared: PreparedBundle
    public let runtimeVersion: String
    private var config: VMConfigV1
    private var state: VMRunState = .stopped
    private let backend: VMBackend?
    private var server: UDSServer?
    private let onShutdown: @Sendable () -> Void
    private var shuttingDown = false

    public init(
        prepared: PreparedBundle, runtimeVersion: String, backend: VMBackend?,
        onShutdown: @escaping @Sendable () -> Void
    ) {
        self.prepared = prepared
        self.runtimeVersion = runtimeVersion
        self.config = prepared.config
        self.backend = backend
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
    }

    /// Stops the server, stops recorded children, removes run files and releases the bundle lock.
    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
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
        case .eventsSubscribe?: return subscribe(request.params, connection)
        case .vmSettingsGet?: return RPCParams.encode(config)
        case .vmStart?, .vmPause?, .vmResume?, .vmSuspend?, .vmStop?:
            guard backend != nil else {
                return .failure(RPCError(.backendUnavailable, "no \(config.backend.rawValue) backend in this build"))
            }
            return .failure(RPCError(.methodNotFound, "\(request.method) is not available yet"))
        case .vmSnapshotList?, .vmSnapshotCreate?, .vmSnapshotDelete?, .vmSnapshotRestore?:
            let (lock, config, state) = (prepared.lock, config, state)
            let method = ControlMethod(rawValue: request.method)
            let params = request.params
            return await Blocking.run { Self.snapshot(method, params, lock: lock, config: config, state: state) }
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
        ])
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

    // MARK: - Snapshots (stopped VM; live snapshots need a backend)

    private struct CreateParams: Decodable {
        var name: String
        var kind: SnapshotMeta.Kind
        var origin: SnapshotMeta.Origin?
    }

    private struct IDParams: Decodable { var id: UUID }

    private static func snapshot(
        _ method: ControlMethod?, _ params: JSONValue?, lock: BundleLock, config: VMConfigV1,
        state: VMRunState
    ) -> Result<JSONValue, RPCError> {
        let store = SnapshotStore(lock: lock)
        do {
            switch method {
            case .vmSnapshotList?:
                return RPCParams.encode(try store.list())
            case .vmSnapshotCreate?:
                let create = try RPCParams.decode(CreateParams.self, from: params).get()
                guard create.kind == .disk else { return .failure(RPCError(.backendUnavailable, "live snapshots need a running backend")) }
                guard state == .stopped else { return .failure(RPCError(.unsupportedLive, "disk snapshots need the VM stopped")) }
                let context = SnapshotContext(
                    deviceSetHash: DeviceSet(config).hash, hostBuild: Self.hostBuild,
                    backendVersion: VMPane.version)
                return RPCParams.encode(try store.create(name: create.name, kind: .disk, origin: create.origin ?? .user, context: context))
            case .vmSnapshotDelete?:
                try store.delete(try RPCParams.decode(IDParams.self, from: params).get().id)
                return .success(.object([:]))
            case .vmSnapshotRestore?:
                guard state == .stopped else { return .failure(RPCError(.unsupportedLive, "restore needs the VM stopped")) }
                let generation = try store.restore(try RPCParams.decode(IDParams.self, from: params).get().id)
                return .success(["generationId": .string(generation.generationId.uuidString)])
            default:
                return .failure(RPCError(.methodNotFound, "unknown snapshot method"))
            }
        } catch let error as RPCError {
            return .failure(error)
        } catch SnapshotError.notFound(let id) {
            return .failure(RPCError(.invalidParams, "no snapshot \(id)"))
        } catch {
            return .failure(RPCError(.internalError, String(describing: error)))
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
