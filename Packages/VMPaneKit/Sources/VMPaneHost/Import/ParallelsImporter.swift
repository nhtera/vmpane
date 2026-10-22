import Foundation
import VMPaneCore
import VMPaneQEMU

/// Makes a VMPane VM from a Parallels `.pvm` (Linux and Windows guests): a new machine (its own id, MAC
/// addresses, EFI variables and, for Windows, TPM) whose disk is the Parallels boot disk converted to a sparse
/// raw image by `qemu-img`. The `.pvm` is only read. On failure or cancellation the half-made VM is deleted.
///
/// A Windows guest's TPM cannot come along: BitLocker asks for its recovery key at the first start (the import
/// sheet says so before importing), and Windows may ask to be activated again.
public struct ParallelsImporter: Sendable {
    public let qemuImg: URL

    public init(qemuImg: URL) {
        self.qemuImg = qemuImg
    }

    /// Imports `pvm` as `name`, a guest of `os` (the sheet's confirmed choice); `progress` hears 0…1.
    public func importVM(
        _ pvm: URL, name: String, os: GuestOS, ops: LibraryOps, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VMBundle {
        guard os != .macos else { throw PVMImportError.macOSGuest }
        let parallels = try ParallelsVM.read(pvm)
        let disk = try ParallelsDisk.read(parallels.disks[0])
        let diskGiB = max(Int((disk.sizeBytes + (1 << 30) - 1) >> 30), 1)
        let bundle = try ops.create(name: name, os: os, diskGiB: diskGiB)
        do {
            try adopt(parallels, into: bundle)
            let target = try bundle.fileURL(relativePath: try ConfigStore.load(bundle).disks[0].file)
            let partial = target.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString.prefix(8)).img")
            defer { try? FileManager.default.removeItem(at: partial) }
            try await convert(disk, to: partial, progress: progress)
            // The raw image is as large as the virtual disk; round up to the whole GiB the config states.
            let handle = try FileHandle(forWritingTo: partial)
            if try handle.seekToEnd() < UInt64(diskGiB) << 30 { try handle.truncate(atOffset: UInt64(diskGiB) << 30) }
            try handle.close()
            guard rename(partial.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            progress(1)
            return bundle
        } catch {
            try? ops.delete(bundle)
            throw error
        }
    }

    /// The Parallels VM's processors and memory, within what this Mac can give.
    private func adopt(_ parallels: ParallelsVM, into bundle: VMBundle) throws {
        guard let lock = try bundle.tryLock(retryingFor: 1) else { throw LibraryOps.VMRunning() }
        defer { lock.release() }
        var config = try ConfigStore.load(bundle)
        if let cpus = parallels.cpuCount { config.cpu.count = min(max(cpus, 1), ProcessInfo.processInfo.activeProcessorCount) }
        if let memory = parallels.memoryMiB {
            let ceiling = max(Int(ProcessInfo.processInfo.physicalMemory >> 20) - 4096, 2048)
            config.memory.mib = min(max(memory, 2048), ceiling)
        }
        try ConfigStore.save(config, holding: lock)
    }

    /// `qemu-img convert -p -f <parallels|raw> -O raw -S 4k`: sparse output, progress on stdout as "(12.34/100%)".
    private func convert(_ disk: ParallelsDisk, to target: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = QEMUSandbox.sandboxExec
        // The sandbox's rules match resolved paths: qemu-img gets them resolved too (/tmp is a link).
        let image = URL(fileURLWithPath: try QEMUSandbox.realPath(disk.image))
        let output = URL(fileURLWithPath: try QEMUSandbox.realPath(target.deletingLastPathComponent())).appendingPathComponent(
            target.lastPathComponent)
        process.arguments = try QEMUSandbox.importArguments(
            qemuImg: qemuImg, source: image, target: output,
            arguments: [
                "convert", "-p", "-f", disk.format == .plain ? "raw" : "parallels", "-O", "raw", "-S", "4k", image.path, output.path,
            ])
        let progressPipe = Pipe()
        let errors = Pipe()
        process.standardOutput = progressPipe
        process.standardError = errors
        progressPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(bytes: handle.availableData, encoding: .utf8) ?? ""
            if let percent = Self.lastPercent(text) { progress(percent / 100 * 0.99) }
        }
        let status = try await CancellableProcess.run(process)
        progressPipe.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard status == 0 else {
            let message = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PVMImportError.unreadable("qemu-img: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// The last "(NN.NN/100%)" in qemu-img's progress output.
    static func lastPercent(_ text: String) -> Double? {
        text.components(separatedBy: "(").reversed().lazy.compactMap { part -> Double? in
            guard let slash = part.firstIndex(of: "/"), part[slash...].hasPrefix("/100%") else { return nil }
            return Double(part[..<slash])
        }.first
    }
}
