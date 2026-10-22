import CryptoKit
import Foundation

/// Copies of a VM that are separate machines: new VM id, MAC addresses, SMBIOS UUID and machine
/// identifier. The machine identifier (and a macOS guest's `aux/MachineIdentifier`) is cleared; the VZ
/// backend creates and persists a new one on first start.
public enum FullClone {
    /// Gives `config` a fresh identity.
    public static func newIdentity(_ config: VMConfigV1) -> VMConfigV1 {
        var config = config
        config.id = UUID()
        for i in config.network.indices {
            config.network[i].macAddress = MachineIdentity.randomMACAddress()
        }
        config.platform.machineIdentifier = nil
        if config.qemu != nil {
            config.qemu?.smbiosUUID = UUID()
        }
        config.mcp.tag = nil  // the integrity tag covers the VM id (`clone` signs it again)
        return config
    }

    /// Clones a stopped bundle to `destination` as a new machine. RAM state, install files (but a cloud image's
    /// pending seed, which becomes the clone's own) and snapshots are not copied: the clone cold boots from the current disks. With `policyKey`, a source agent policy that
    /// checks out is tagged for the clone; one that does not stays untagged (off), so cloning does not make a
    /// hand-edited level count.
    @discardableResult
    public static func clone(
        holding lock: BundleLock, to destination: URL, name: String, policyKey: SymmetricKey? = nil
    ) throws -> VMBundle {
        let source = lock.bundle
        let original = try ConfigStore.load(source)
        var config = newIdentity(original)
        config.name = name
        if let policyKey, !PolicyIntegrity.effective(original, key: policyKey).tampered {
            config = PolicyIntegrity.signed(config, key: policyKey)
        }
        let fm = FileManager.default
        // VMPane's SSH forward: a port of the clone's own (both may run at once).
        for index in config.portForwards.indices where config.portForwards[index].id == "ssh" {
            let rule = config.portForwards[index]
            if rule.guestPort == 22, let port = LoopbackPort.free(avoiding: [rule.hostPort]) { config.portForwards[index].hostPort = port }
        }
        // A cloud image's seed not used up yet (`install/cidata`): the clone gets its own copy, as a new machine for
        // cloud-init.
        let seed = config.install?.cloudInit
        let seedFolder: String? = seed == nil ? nil : "cidata"
        if let seed, let seedFolder, let index = config.removable.firstIndex(where: { $0.id == seed }) {
            config.removable[index].path = CloudInitSeed.iso(of: destination.appendingPathComponent("install/\(seedFolder)")).path
        }
        return try VMBundle.createStaged(at: destination, config: config) { target in
            for entry in try fm.contentsOfDirectory(at: source.currentDirectory, includingPropertiesForKeys: nil)
            where !["state", "generation.json", "aux"].contains(entry.lastPathComponent) {
                try CloneFile.clone(entry, to: target.currentDirectory.appendingPathComponent(entry.lastPathComponent))
            }
            for entry in try fm.contentsOfDirectory(at: source.auxDirectory, includingPropertiesForKeys: nil)
            where entry.lastPathComponent != "MachineIdentifier" {
                try CloneFile.clone(entry, to: target.auxDirectory.appendingPathComponent(entry.lastPathComponent))
            }
            let original = seedFolder.map { source.installDirectory.appendingPathComponent($0, isDirectory: true) }
            if let original, (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                fm.fileExists(atPath: original.path)
            {
                let copy = target.installDirectory.appendingPathComponent(original.lastPathComponent, isDirectory: true)
                try fm.createDirectory(
                    at: target.installDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: original, to: copy)
                _ = try CloudInitSeed.reissue(copy)
            }
            try DurableWrite.syncTree(target.currentDirectory)
        }
    }

    /// What a copy of the VM named `name`, at `url`, is called: its file's name, or "<name> copy" when that is
    /// the original's name too.
    public static func copyName(of name: String, at url: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        return fileName != name && !fileName.isEmpty ? fileName : "\(name) copy"
    }

    /// In-place identity change for a bundle found to duplicate another (e.g. a Finder copy). Saved RAM
    /// state is deleted: it belongs to the other machine's identity. It is renamed (`copyName`), so the library does
    /// not list two VMs alike.
    public static func regenerateIdentity(holding lock: BundleLock) throws -> VMConfigV1 {
        let bundle = lock.bundle
        var config = newIdentity(try ConfigStore.load(bundle))
        config.name = copyName(of: config.name, at: bundle.url)
        let fm = FileManager.default
        try? fm.removeItem(at: bundle.auxDirectory.appendingPathComponent("MachineIdentifier"))
        if fm.fileExists(atPath: bundle.stateDirectory.path) {
            for entry in try fm.contentsOfDirectory(at: bundle.stateDirectory, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: entry)
            }
        }
        try Generation().write(to: bundle.generationURL)
        try ConfigStore.save(config, holding: lock)
        return config
    }
}
