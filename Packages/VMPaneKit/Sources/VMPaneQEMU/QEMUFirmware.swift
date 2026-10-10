import Darwin
import Foundation
import VMPaneCore

/// UEFI firmware files for a QEMU VM. The shipped code and variable template are unpadded (size budget);
/// the virt board's pflash devices are 64 MiB each, so both are extended with zeros (sparse: no disk cost).
public enum QEMUFirmware {
    public static let flashSize: off_t = 64 << 20

    /// Creates the VM's variable store from the template when it has none (first start). Returns whether it
    /// did. An existing store is never replaced: it holds the VM's boot entries and enrolled keys.
    @discardableResult
    public static func ensureVariables(_ layout: QEMULayout) throws -> Bool {
        let target = layout.efiVariables
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        guard FileManager.default.fileExists(atPath: layout.shippedVariablesTemplate.path) else {
            throw QEMUConfigError.missingFile(layout.shippedVariablesTemplate.path)
        }
        try padded(copyOf: layout.shippedVariablesTemplate, to: target)
        return true
    }

    /// The firmware code for this start, in the run directory (replaced each start, so a QEMU update
    /// brings its firmware with it).
    public static func prepareCode(_ layout: QEMULayout) throws {
        guard FileManager.default.fileExists(atPath: layout.shippedFirmwareCode.path) else {
            throw QEMUConfigError.missingFile(layout.shippedFirmwareCode.path)
        }
        try? FileManager.default.removeItem(at: layout.firmwareCode)
        try padded(copyOf: layout.shippedFirmwareCode, to: layout.firmwareCode)
    }

    /// Clones (or copies) `source` to a temporary name next to `target`, extends it to the flash size,
    /// syncs it and renames it into place.
    static func padded(copyOf source: URL, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            do {
                try CloneFile.clone(source, to: temp)
            } catch CloneError.unsupported {
                try FileManager.default.copyItem(at: source, to: temp)
            }
            let fd = open(temp.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError.current() }
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0, ftruncate(fd, flashSize) == 0 else { throw POSIXError.current() }
            try DurableWrite.fullSync(fd)
            guard rename(temp.path, target.path) == 0 else { throw POSIXError.current() }
            try DurableWrite.syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
