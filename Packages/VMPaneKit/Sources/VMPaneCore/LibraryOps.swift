import Foundation

/// Library operations that need no running helper (list, create, clone, delete, import), behind the
/// same policy gate as helper requests. Phase 10 supplies real identities and the audit sink.
public struct LibraryOps: Sendable {
    public let library: VMLibrary
    public let identity: ClientIdentity
    /// Called for every decision (Phase 10 writes `mcp-audit.jsonl`).
    public var audit: @Sendable (_ method: String, _ vm: UUID?, _ decision: PolicyDecision) -> Void = { _, _, _ in }

    public init(library: VMLibrary, identity: ClientIdentity) {
        self.library = library
        self.identity = identity
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
        let clone = try FullClone.clone(holding: lock, to: uniqueURL(for: name), name: name)
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
    }

    /// Adds an existing bundle (e.g. one copied from another Mac) to the library.
    public func importBundle(at url: URL) throws -> VMBundle {
        try gate("vm.import", vm: nil, level: .off)
        let bundle = try VMBundle.open(url)
        try library.register(bundle)
        return bundle
    }

    private func gate(_ method: String, vm: UUID?, level: PolicyLevel) throws {
        let decision = PolicyEnforcer.decide(
            method: method, params: nil, level: level, identity: identity,
            context: PolicyContext(clipboardAllowWithAgents: false))
        audit(method, vm, decision)
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
