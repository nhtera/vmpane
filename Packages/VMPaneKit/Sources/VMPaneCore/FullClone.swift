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
        config.mcp.tag = nil  // the integrity tag covers the VM id; the app re-signs it
        return config
    }

    /// Clones a stopped bundle to `destination` as a new machine. RAM state, install files and snapshots
    /// are not copied: the clone cold boots from the current disks.
    @discardableResult
    public static func clone(holding lock: BundleLock, to destination: URL, name: String) throws -> VMBundle {
        let source = lock.bundle
        var config = newIdentity(try ConfigStore.load(source))
        config.name = name
        let fm = FileManager.default
        return try VMBundle.createStaged(at: destination, config: config) { target in
            for entry in try fm.contentsOfDirectory(at: source.currentDirectory, includingPropertiesForKeys: nil)
            where !["state", "generation.json", "aux"].contains(entry.lastPathComponent) {
                try CloneFile.clone(entry, to: target.currentDirectory.appendingPathComponent(entry.lastPathComponent))
            }
            for entry in try fm.contentsOfDirectory(at: source.auxDirectory, includingPropertiesForKeys: nil)
            where entry.lastPathComponent != "MachineIdentifier" {
                try CloneFile.clone(entry, to: target.auxDirectory.appendingPathComponent(entry.lastPathComponent))
            }
            try DurableWrite.syncTree(target.currentDirectory)
        }
    }

    /// In-place identity change for a bundle found to duplicate another (e.g. a Finder copy). Saved RAM
    /// state is deleted: it belongs to the other machine's identity.
    public static func regenerateIdentity(holding lock: BundleLock) throws -> VMConfigV1 {
        let bundle = lock.bundle
        let config = newIdentity(try ConfigStore.load(bundle))
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
