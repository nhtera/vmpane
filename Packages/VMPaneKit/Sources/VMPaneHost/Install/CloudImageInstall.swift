import Foundation
import VMPaneCore
import VMPaneQEMU

/// A Linux VM from a distribution's cloud image, with no installer: the image (downloaded, SHA-256 checked) is
/// converted to a raw disk once per build by the sandboxed `qemu-img` and kept in the cache; each VM's disk is an APFS
/// clone of it grown to the VM's size, and a cloud-init seed (`CloudInitSeed`) sets up its user, SSH and VMPane's guest
/// tools on the first boot. SSH is forwarded from 127.0.0.1 only. The helper removes the seed once the guest tools run.
public enum CloudImageInstall {
    public static let seedID = "cidata"
    /// The seed's folder in the bundle's `install/` (its ISO beside it): never in `current/`, so no snapshot keeps it.
    public static let seedFolder = "cidata"

    public static func seedDirectory(in bundle: VMBundle) -> URL {
        bundle.installDirectory.appendingPathComponent(seedFolder, isDirectory: true)
    }

    public struct Account: Sendable, Equatable {
        public var userName: String
        public var password: String
        public var sshKey: String?
        public var desktop: Bool

        public init(userName: String, password: String, sshKey: String? = nil, desktop: Bool = false) {
            self.userName = userName
            self.password = password
            self.sshKey = sshKey
            self.desktop = desktop
        }
    }

    public enum Stage: Sendable, Equatable {
        case downloading(received: Int64, total: Int64?)
        case converting(fraction: Double)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notCloudImage
        case convert(String)

        public var description: String {
            switch self {
            case .notCloudImage: "this catalog image is not a cloud image"
            case .convert(let message): "the cloud image could not be converted: \(message)"
            }
        }
    }

    /// Converted base disks, in `~/Library/Caches/app.vmpane.mac/Cloud/`.
    public static var cache: ImageCache { .standard("Cloud") }

    /// Whether `image`'s base disk is made already (a new VM needs no download).
    public static func isReady(_ image: ImageCatalog.Image, cache: ImageCache = cache) -> Bool {
        FileManager.default.fileExists(atPath: baseFile(image, cache: cache).path)
    }

    /// `<id>-<16 hex>.raw`: a base of the image `id` (any build).
    static func isBase(_ name: String, of id: String) -> Bool {
        guard name.hasPrefix(id + "-"), name.hasSuffix(".raw") else { return false }
        let hash = name.dropFirst(id.count + 1).dropLast(4)
        return hash.count == 16 && hash.allSatisfy(\.isHexDigit)
    }

    static func baseFile(_ image: ImageCatalog.Image, cache: ImageCache) -> URL {
        cache.directory.appendingPathComponent("\(image.id)-\(image.sha256.prefix(16)).raw")
    }

    /// Whether `image` was converted already: a new VM only clones it.
    public static func hasBase(_ image: ImageCatalog.Image, cache: ImageCache = cache) -> Bool {
        FileManager.default.fileExists(atPath: baseFile(image, cache: cache).path)
    }

    /// The raw base disk for `image`: downloaded and checked, then converted once (`<id>-<sha256 prefix>.raw`).
    public static func base(
        _ image: ImageCatalog.Image, qemuImg: URL, cache: ImageCache = cache, session: URLSession = .shared,
        progress: @escaping @Sendable (Stage) -> Void = { _ in }
    ) async throws -> URL {
        guard image.isCloudImage else { throw Failure.notCloudImage }
        let base = baseFile(image, cache: cache)
        if FileManager.default.fileExists(atPath: base.path) { return base }
        // One create of an image makes its base; another waits, then finds it (the download goes once it is converted).
        try await FileGate.shared.enter(base.path)
        do {
            let made = try await makeBase(image, qemuImg: qemuImg, cache: cache, session: session, progress: progress)
            await FileGate.shared.leave(base.path)
            return made
        } catch {
            await FileGate.shared.leave(base.path)
            throw error
        }
    }

    private static func makeBase(
        _ image: ImageCatalog.Image, qemuImg: URL, cache: ImageCache, session: URLSession, progress: @escaping @Sendable (Stage) -> Void
    ) async throws -> URL {
        let base = baseFile(image, cache: cache)
        if FileManager.default.fileExists(atPath: base.path) { return base }
        let qcow2 = try await cache.ensure(image, session: session) { progress(.downloading(received: $0, total: $1)) }
        try Task.checkCancellation()
        // A partial of its own: another create of the same image may be converting it too; the first to finish wins.
        let partial = cache.directory.appendingPathComponent(".\(base.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await convert(qcow2, to: partial, qemuImg: qemuImg) { progress(.converting(fraction: $0)) }
        guard renamex_np(partial.path, base.path, UInt32(RENAME_EXCL)) == 0 || errno == EEXIST else { throw POSIXError.current() }
        // The base is what VMs are cloned from: the download is not needed again, nor older builds' bases.
        try? FileManager.default.removeItem(at: qcow2)
        let others = (try? FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil)) ?? []
        for other in others where other != base && isBase(other.lastPathComponent, of: image.id) {
            try? FileManager.default.removeItem(at: other)
        }
        return base
    }

    /// `config` with its disk a clone of `base` (the blank disk replaced) grown to its size, the seed for `account`
    /// attached, and SSH forwarded from 127.0.0.1. Holds the bundle's lock.
    public static func apply(
        _ config: VMConfigV1, base: URL, image: ImageCatalog.Image, account: Account, holding lock: BundleLock
    ) throws -> VMConfigV1 {
        var config = config
        let disk = try lock.bundle.fileURL(relativePath: config.disks[0].file)
        let size = max(
            UInt64(config.disks[0].sizeGiB) << 30, (try? base.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0)
        try FileManager.default.removeItem(at: disk)
        do {
            try CloneFile.clone(base, to: disk)
        } catch CloneError.unsupported {
            try FileManager.default.copyItem(at: base, to: disk)
        }
        let gib = (size + (1 << 30) - 1) >> 30
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: gib << 30)
        try handle.close()
        config.disks[0].sizeGiB = Int(gib)

        guard let distro = CloudInitSeed.Distro(rawValue: image.distro ?? "") else { throw Failure.notCloudImage }
        let seed = try CloudInitSeed(
            distro: distro, hostName: hostName(config.name), userName: account.userName,
            passwordHash: SHA512Crypt.hash(account.password), sshKey: account.sshKey, desktop: account.desktop)
        try FileManager.default.createDirectory(
            at: lock.bundle.installDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let iso = try seed.write(to: seedDirectory(in: lock.bundle))
        config.removable.removeAll { $0.id == seedID }
        config.removable.append(Extensible(RemovableConfig(id: seedID, path: iso.path, bus: .virtio)))
        config.install = Extensible(InstallConfig(cloudInit: seedID, desktop: account.desktop ? true : nil))
        if !config.portForwards.contains(where: { $0.guestPort == 22 }), let port = LoopbackPort.free() {
            config.portForwards.append(
                Extensible(
                    PortForwardConfig(id: "ssh", proto: .tcp, hostAddress: "127.0.0.1", hostPort: port, guestPort: 22, origin: .user)))
        }
        return config
    }

    /// Whether the first boot is over: the guest tools ran and the seed's data went (`consume`).
    public static func isUsed(_ bundle: VMBundle) -> Bool {
        !FileManager.default.fileExists(atPath: seedDirectory(in: bundle).path)
    }

    /// The guest tools run: the seed's data goes at once (it holds the password's hash). Its ISO becomes an empty
    /// placeholder (a new file renamed into place: the running VM keeps reading the one it opened), so the VM's
    /// devices and config stay as they are until it stops (`finished`), and a saved state still resumes.
    public static func consume(_ bundle: VMBundle) throws {
        let iso = CloudInitSeed.iso(of: seedDirectory(in: bundle))
        let placeholder = bundle.installDirectory.appendingPathComponent(".\(seedFolder)-\(UUID().uuidString).iso")
        guard FileManager.default.createFile(atPath: placeholder.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: placeholder)
        try handle.truncate(atOffset: 1 << 20)
        try handle.close()
        guard rename(placeholder.path, iso.path) == 0 else {
            unlink(placeholder.path)
            throw POSIXError.current()
        }
        try FileManager.default.removeItem(at: seedDirectory(in: bundle))
    }

    /// The VM stopped (or starts) after its first boot: the config without the seed's device and the install record,
    /// and the placeholder deleted; else nil.
    public static func finished(_ config: VMConfigV1, bundle: VMBundle) -> VMConfigV1? {
        guard let seed = config.install?.cloudInit, isUsed(bundle) else { return nil }
        try? FileManager.default.removeItem(at: CloudInitSeed.iso(of: seedDirectory(in: bundle)))
        var config = config
        config.removable.removeAll { $0.id == seed }
        config.install = nil
        return config
    }

    /// A host name from the VM's name: letters, digits and hyphens.
    static func hostName(_ name: String) -> String {
        let mapped = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let joined = mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = String(joined.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "vmpane" : trimmed
    }

    /// `qemu-img convert -p -f qcow2 -O raw -S 4k` in the import sandboxes.
    static func convert(_ source: URL, to target: URL, qemuImg: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = QEMUSandbox.sandboxExec
        let image = URL(fileURLWithPath: try QEMUSandbox.realPath(source))
        let output = URL(fileURLWithPath: try QEMUSandbox.realPath(target.deletingLastPathComponent()))
            .appendingPathComponent(target.lastPathComponent)
        process.arguments = try QEMUSandbox.importArguments(
            qemuImg: qemuImg, source: image, target: output,
            arguments: ["convert", "-p", "-f", "qcow2", "-O", "raw", "-S", "4k", image.path, output.path])
        let progressPipe = Pipe()
        let errors = Pipe()
        process.standardOutput = progressPipe
        process.standardError = errors
        progressPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(bytes: handle.availableData, encoding: .utf8) ?? ""
            if let percent = ParallelsImporter.lastPercent(text) { progress(percent / 100) }
        }
        let status = try await CancellableProcess.run(process)
        progressPipe.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard status == 0 else {
            try? FileManager.default.removeItem(at: target)
            let message = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.convert(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
