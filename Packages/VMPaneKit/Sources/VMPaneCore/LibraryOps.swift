import Foundation

/// Library operations that need no running helper (list, create, clone, delete, import), behind the
/// same policy gate as helper requests.
public struct LibraryOps: Sendable {
    public let library: VMLibrary
    public let identity: ClientIdentity
    /// Called for every decision, with the VM's policy level (`recordingInVMLogs`).
    public var audit: @Sendable (_ method: String, _ vm: UUID?, _ level: PolicyLevel, _ decision: PolicyDecision) -> Void = { _, _, _, _ in
    }

    public init(library: VMLibrary, identity: ClientIdentity) {
        self.library = library
        self.identity = identity
    }

    /// These operations, recorded in the VM's audit log (`logs/mcp-audit.jsonl`) like its helper's requests:
    /// `label` and `kind` as the helper would record this client, `session` the agent session if any.
    public func recordingInVMLogs(label: String, kind: String, session: String? = nil) -> LibraryOps {
        var ops = self
        let library = library
        ops.audit = { method, vm, level, decision in
            guard let vm, let item = try? library.items().first(where: { $0.id == vm }) else { return }
            let reason: String? = if case .deny(let why) = decision { why } else { nil }
            let entry = AuditEntry(
                session: session, identity: label, kind: kind, method: method, policy: level.rawValue,
                result: reason == nil ? "ok" : "denied", reason: reason)
            try? AuditLog(bundle: item.bundle).append(entry)
        }
        return ops
    }

    public struct PolicyDenied: Error, Equatable, Sendable { public let reason: String }
    /// The VM is running (its helper holds the bundle lock): stop it first.
    public struct VMRunning: Error, Equatable, Sendable {
        public init() {}
    }

    /// VMs this client may see: all for the app; for others only VMs whose policy is at least `observe`.
    public func list() throws -> [VMLibrary.Item] {
        try gate("library.list", vm: nil, level: .off)
        return try library.items().filter { item in
            identity == .ui || identity == .operator || (item.config.map(policy)?.level ?? .off) >= .observe
        }
    }

    /// The agent policy that applies to `config` (its saved level only with a valid tag).
    public func policy(_ config: VMConfigV1) -> PolicyIntegrity.Effective {
        PolicyIntegrity.effective(config, key: PolicyKeyFile(paths: library.paths).key(create: false))
    }

    /// Creates a bundle in the default library directory, with an empty sparse root disk.
    public func create(name: String, os: GuestOS, diskGiB: Int) throws -> VMBundle {
        try gate("vm.create", vm: nil, level: .off)
        let config = VMConfigV1(VMConfigFields.new(name: name, os: os, diskGiB: diskGiB, macAddress: MachineIdentity.randomMACAddress()))
        try FileManager.default.createDirectory(
            at: library.paths.defaultLibrary, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let bundle = try VMBundle.createStaged(at: uniqueURL(for: name), config: config) { staged in
            try DiskImage.createRaw(at: staged.fileURL(relativePath: config.disks[0].file), sizeBytes: UInt64(diskGiB) << 30)
        }
        try library.register(bundle)
        return bundle
    }

    /// Clones a stopped VM as a new machine.
    public func clone(_ bundle: VMBundle, name: String) throws -> VMBundle {
        let config = try ConfigStore.load(bundle)
        try gate("vm.clone", vm: config.id, level: policy(config).level)
        guard let lock = try bundle.tryLock(retryingFor: 0.5) else { throw VMRunning() }
        defer { lock.release() }
        let clone = try FullClone.clone(
            holding: lock, to: uniqueURL(for: name), name: name, policyKey: PolicyKeyFile(paths: library.paths).key(create: false))
        try library.register(clone)
        return clone
    }

    /// Deletes a stopped VM and removes it from the library.
    public func delete(_ bundle: VMBundle) throws {
        let config = try ConfigStore.load(bundle)
        try gate("vm.delete", vm: config.id, level: policy(config).level)
        guard let lock = try bundle.tryLock(retryingFor: 0.5) else { throw VMRunning() }
        try bundle.delete(holding: lock)
        try library.unregister(id: config.id)
        try? GuestCredentials.store(paths: library.paths).delete(for: config.id)
    }

    // MARK: - Stopped VMs, with no helper (the app's inspector)

    /// Changes a stopped VM's hardware: processors, memory, display size, and the disk grown (never shrunk; the
    /// guest grows its file system itself). Under the VM's lock: refused while a helper holds it (`VMRunning`).
    public func updateStopped(_ bundle: VMBundle, _ change: (inout StoppedSettings) -> Void) throws -> VMConfigV1 {
        guard identity == .ui else { throw PolicyDenied(reason: "only the VMPane app changes a stopped VM's settings") }
        guard let lock = try bundle.tryLock(retryingFor: 0.5) else { throw VMRunning() }
        defer { lock.release() }
        var config = try ConfigStore.load(bundle)
        var settings = StoppedSettings(config)
        change(&settings)
        guard settings.diskGiB >= config.disks[0].sizeGiB else { throw StoppedSettings.Problem.diskShrink }
        guard settings.cpuCount >= 1, settings.memoryMiB >= 1024 else { throw StoppedSettings.Problem.tooSmall }
        if settings.diskGiB > config.disks[0].sizeGiB {
            let disk = try bundle.fileURL(relativePath: config.disks[0].file)
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: UInt64(settings.diskGiB) << 30)
            try handle.close()
        }
        settings.apply(to: &config)
        try ConfigStore.save(config, holding: lock)
        return config
    }

    /// A stopped VM's snapshots, newest first (with its lock: `VMRunning` while a helper holds it).
    public func snapshots(of bundle: VMBundle) throws -> [SnapshotMeta] {
        try withStoppedSnapshots(bundle) { try $0.list().reversed() }
    }

    /// A disk snapshot of a stopped VM.
    @discardableResult
    public func createSnapshot(named name: String, in bundle: VMBundle) throws -> SnapshotMeta {
        let config = try ConfigStore.load(bundle)
        let context = SnapshotContext(deviceSetHash: DeviceSet(config).hash, hostBuild: Self.hostBuild, backendVersion: VMPane.version)
        return try withStoppedSnapshots(bundle) { try $0.create(name: name, kind: .disk, origin: .user, context: context) }
    }

    /// This Mac's macOS build (`kern.osversion`), as snapshots record it.
    static let hostBuild: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }()

    public func renameSnapshot(_ id: UUID, to name: String, in bundle: VMBundle) throws {
        try withStoppedSnapshots(bundle) { try $0.setName(name, of: id) }
    }

    /// Restores a stopped VM to snapshot `id` (its RAM state too, for a live one: the next start resumes it).
    public func restoreSnapshot(_ id: UUID, in bundle: VMBundle) throws {
        try withStoppedSnapshots(bundle) { _ = try $0.restore(id) }
    }

    public func deleteSnapshot(_ id: UUID, in bundle: VMBundle) throws {
        try withStoppedSnapshots(bundle) { try $0.delete(id) }
    }

    private func withStoppedSnapshots<T>(_ bundle: VMBundle, _ body: (SnapshotStore) throws -> T) throws -> T {
        guard identity == .ui else { throw PolicyDenied(reason: "only the VMPane app manages a stopped VM's snapshots") }
        guard let lock = try bundle.tryLock(retryingFor: 0.5) else { throw VMRunning() }
        defer { lock.release() }
        let store = SnapshotStore(lock: lock)
        try store.recover()
        return try body(store)
    }

    /// Adds an existing bundle (e.g. one copied from another Mac) to the library.
    public func importBundle(at url: URL) throws -> VMBundle {
        try gate("vm.import", vm: nil, level: .off)
        let bundle = try VMBundle.open(url)
        try library.register(bundle)
        return bundle
    }

    private func gate(_ method: String, vm: UUID?, level: PolicyLevel) throws {
        // The kill switch stops agents here too (operators and the app are not agents).
        if identity == .automated, method != "mcp.disableAll", KillSwitch.isEngaged(paths: library.paths) {
            let decision = PolicyDecision.deny("AI agents are stopped (VMPane's kill switch)")
            audit(method, vm, level, decision)
            throw PolicyDenied(reason: "AI agents are stopped (VMPane's kill switch)")
        }
        let decision = PolicyEnforcer.decide(
            method: method, params: nil, level: level, identity: identity,
            context: PolicyContext(clipboardAllowWithAgents: false))
        audit(method, vm, level, decision)
        if case .deny(let reason) = decision { throw PolicyDenied(reason: reason) }
    }

    private func uniqueURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = library.paths.defaultLibrary.appendingPathComponent("\(safe).\(VMPane.bundleExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = library.paths.defaultLibrary.appendingPathComponent("\(safe) \(counter).\(VMPane.bundleExtension)")
            counter += 1
        }
        return url
    }
}
