import Foundation
import VMPaneCore
import VMPaneHost

/// Turns a finished wizard into a VM ready to install: a new bundle in the library, its settings, and the
/// installer it boots (a downloaded or local macOS restore image, a Linux ISO, or a Windows ISO with the
/// unattended install VMPane runs). Downloads and checks come first, with no VM in the library yet: quitting then
/// leaves none (the download resumes next time). The bundle is marked unfinished until its settings are saved, so
/// one left by a quit in those seconds is never taken for a VM ready to run. A failed create leaves nothing behind.
public struct VMCreator: Sendable {
    /// Everything the create needs, taken from the wizard on the main actor.
    public struct Request: Sendable {
        public var os: GuestOS
        public var name: String
        public var diskGiB: Int
        public var source: WizardModel.Source
        /// Windows only.
        public var unattend: UnattendInput?
        /// Keep the account's password (`GuestCredentials`): for Copy Password, and for agent sign-in when the VM allows it.
        public var keepPassword = false
        /// Linux cloud images: the account cloud-init creates.
        public var cloudAccount: CloudImageInstall.Account?
        public var configure: @Sendable (inout VMConfigV1) -> Void

        public init(
            os: GuestOS, name: String, diskGiB: Int, source: WizardModel.Source, unattend: UnattendInput? = nil,
            keepPassword: Bool = false, cloudAccount: CloudImageInstall.Account? = nil,
            configure: @escaping @Sendable (inout VMConfigV1) -> Void = { _ in }
        ) {
            self.os = os
            self.name = name
            self.diskGiB = diskGiB
            self.source = source
            self.unattend = unattend
            self.keepPassword = keepPassword
            self.cloudAccount = cloudAccount
            self.configure = configure
        }
    }

    public enum Progress: Sendable, Equatable {
        case creating
        case downloading(received: Int64, total: Int64?)
        /// Checking a file downloaded before.
        case verifying
        case preparing
    }

    let ops: LibraryOps
    let windowsTools: URL?
    /// The app's `qemu-img` (cloud images are converted with it, sandboxed), and where converted cloud images stay.
    let qemuImg: URL
    let cloudCache: ImageCache

    public init(
        ops: LibraryOps, windowsTools: URL? = WindowsInstall.bundledTools(),
        qemuImg: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/qemu/bin/qemu-img"),
        cloudCache: ImageCache = CloudImageInstall.cache
    ) {
        self.ops = ops
        self.windowsTools = windowsTools
        self.qemuImg = qemuImg
        self.cloudCache = cloudCache
    }

    /// Makes the VM; `made` gets its bundle as soon as it is in the library (still unfinished).
    public func create(
        _ request: Request, progress: @escaping @Sendable (Progress) -> Void = { _ in }, made: @escaping @Sendable (URL) -> Void = { _ in }
    ) async throws -> VMBundle {
        progress(.creating)
        try checkSpace(for: request.source)
        let media = try await fetch(request, progress: progress)
        try Task.checkCancellation()
        progress(.preparing)
        let ops = ops
        let bundle = try await Blocking.run {
            try ops.create(name: request.name, os: request.os, diskGiB: request.diskGiB, unfinished: true)
        }
        made(bundle.url)
        do {
            try await prepare(bundle, request, media)
            try Task.checkCancellation()  // Cancel while the disk was prepared: nothing is kept
            let password = request.unattend?.password ?? request.cloudAccount?.password
            if request.keepPassword, let password {
                let id = try ConfigStore.load(bundle).id
                try GuestCredentials.store(paths: ops.library.paths).save(password, for: id, name: request.name)
            }
            try bundle.markFinished()
            return bundle
        } catch {
            try? await Blocking.run { try ops.delete(bundle) }
            throw error
        }
    }

    /// What the install boots, downloaded and checked.
    private enum Media: Sendable {
        case cloudBase(URL)
        case restoreImage(URL)
        case iso(URL)
        case windowsISO
    }

    /// Refuses a download that would leave the Mac's disk nearly full (it would stop part way, or fill it).
    private func checkSpace(for source: WizardModel.Source) throws {
        let (bytes, cache): (Int64, ImageCache)
        switch source {
        case .macCatalog(let image) where !ImageCache.ipsw.has(image): (bytes, cache) = (image.sizeBytes, .ipsw)
        // Converted already: a VM only clones it. Else downloaded (unless it was), then converted to a raw base, which
        // takes about twice the download at most.
        case .linuxCatalog(let image) where image.isCloudImage && !CloudImageInstall.hasBase(image, cache: cloudCache):
            (bytes, cache) = (image.sizeBytes * (cloudCache.has(image) ? 2 : 3), cloudCache)
        case .linuxCatalog(let image) where !image.isCloudImage && !ImageCache.iso.has(image): (bytes, cache) = (image.sizeBytes, .iso)
        default: return
        }
        try SpaceGuard.require(UInt64(max(0, bytes)), at: cache.directory)
    }

    private func fetch(_ request: Request, progress: @escaping @Sendable (Progress) -> Void) async throws -> Media {
        let downloading: @Sendable (Int64, Int64?) -> Void = { progress(.downloading(received: $0, total: $1)) }
        switch request.source {
        case .linuxCatalog(let image) where image.isCloudImage:
            let base = try await CloudImageInstall.base(image, qemuImg: qemuImg, cache: cloudCache) { stage in
                switch stage {
                case .downloading(let received, let total): progress(.downloading(received: received, total: total))
                case .converting: progress(.preparing)
                }
            }
            return .cloudBase(base)
        case .macCatalog(let image):
            if ImageCache.ipsw.has(image) { progress(.verifying) }
            return .restoreImage(try await ImageCache.ipsw.ensure(image, progress: downloading))
        case .macRestoreImage(let url):
            return .restoreImage(url)
        case .linuxCatalog(let image):
            if ImageCache.iso.has(image) { progress(.verifying) }
            return .iso(try await ImageCache.iso.ensure(image, progress: downloading))
        case .linuxISO(let url):
            return .iso(url)
        case .windowsISO:
            return .windowsISO
        }
    }

    private func prepare(_ bundle: VMBundle, _ request: Request, _ media: Media) async throws {
        var config = try ConfigStore.load(bundle)
        request.configure(&config)
        switch media {
        case .restoreImage(let ipsw): config.install = Extensible(InstallConfig(restoreImage: ipsw.path))
        case .iso(let iso): config = try LinuxInstall.prepare(config, iso: iso)
        case .cloudBase, .windowsISO: break
        }
        let tools = windowsTools
        // The app chose the agent policy: tagged, so it counts (PolicyIntegrity).
        let key = PolicyKeyFile(paths: ops.library.paths).key(create: true)
        let configured = key.map { PolicyIntegrity.signed(config, key: $0) } ?? config
        try await Blocking.run {
            guard let lock = try bundle.tryLock() else { throw CreateError.bundleBusy }
            defer { lock.release() }
            var config = configured
            if case .windowsISO(let iso) = request.source {
                guard let unattend = request.unattend else { throw CreateError.missingAccount }
                config = try WindowsInstall.prepare(config, iso: iso, input: unattend, tools: tools, holding: lock)
            }
            if case .linuxCatalog(let image) = request.source, case .cloudBase(let base) = media {
                guard let account = request.cloudAccount else { throw CreateError.missingAccount }
                config = try CloudImageInstall.apply(config, base: base, image: image, account: account, holding: lock)
            }
            try ConfigStore.save(config, holding: lock)
        }
    }

    public enum CreateError: Error, Equatable, Sendable, CustomStringConvertible {
        case bundleBusy
        case missingAccount

        public var description: String {
            switch self {
            case .bundleBusy: "The new VM is in use by another process."
            case .missingAccount: "The account is missing."
            }
        }
    }
}

extension WizardModel {
    /// The create request for this wizard (call once `problems(in: .summary)` is empty).
    public func request(locale: Locale = .current, timeZone: TimeZone = .current, now: Date = Date()) -> VMCreator.Request? {
        guard let os, let source, canLeave(.summary) else { return nil }
        var unattend: UnattendInput?
        if os == .windows {
            let languageTag = locale.identifier(.bcp47)
            unattend = UnattendInput(
                locale: languageTag, timeZone: UnattendInput.windowsTimeZone(for: timeZone.identifier),
                computerName: WizardModel.computerName(from: name), userName: userName.trimmingCharacters(in: .whitespaces),
                password: password, editionName: edition, eulaAcceptedAt: eulaAccepted ? now : nil)
        }
        // A value snapshot: the closure runs off the main actor.
        let wizard = Snapshot(self)
        return VMCreator.Request(
            os: os, name: name.trimmingCharacters(in: .whitespaces), diskGiB: diskGiB, source: source, unattend: unattend,
            keepPassword: needsAccount && (keepSignInPassword || usesGeneratedPassword), cloudAccount: cloudAccount,
            configure: { wizard.configure(&$0) })
    }

    /// The settings `configure` writes, copied off the main actor.
    struct Snapshot: Sendable {
        let name: String, cpuCount: Int, memoryGiB: Int, audioOutput: Bool, microphone: Bool, clipboard: Bool
        let mcpPolicy: PolicyLevel, sharedFolders: [URL], rosetta: Bool, os: GuestOS?, signIn: Bool

        @MainActor init(_ model: WizardModel) {
            name = model.name
            cpuCount = model.cpuCount
            memoryGiB = model.memoryGiB
            audioOutput = model.audioOutput
            microphone = model.microphone
            clipboard = model.clipboard
            mcpPolicy = model.mcpPolicy
            sharedFolders = model.sharedFolders
            rosetta = model.rosetta
            os = model.os
            signIn = model.needsAccount && model.keepSignInPassword
        }

        func configure(_ config: inout VMConfigV1) {
            config.name = name.trimmingCharacters(in: .whitespaces)
            config.cpu.count = cpuCount
            config.memory.mib = memoryGiB << 10
            config.audio.output = audioOutput
            config.audio.input = microphone
            config.clipboard.mode = clipboard ? .both : .off
            config.mcp.policy = mcpPolicy
            if signIn { config.mcp.signIn = true }
            var shareNames: Set<String> = []
            config.shares = sharedFolders.enumerated().map { index, folder in
                // Share names are directory names in the guest: unique, so a second "Documents" becomes "Documents 2".
                var shareName = folder.lastPathComponent
                var suffix = 2
                while !shareNames.insert(shareName).inserted {
                    shareName = "\(folder.lastPathComponent) \(suffix)"
                    suffix += 1
                }
                return Extensible(ShareConfig(id: "share-\(index + 1)", name: shareName, hostPath: folder.path, readOnly: false))
            }
            if os == .linux { config.vz?.rosetta = rosetta }
        }
    }
}
