import Foundation
import VMPaneCore
import VMPaneHost

/// Turns a finished wizard into a VM ready to install: a new bundle in the library, its settings, and the
/// installer it boots (a downloaded or local macOS restore image, a Linux ISO, or a Windows ISO with the
/// unattended install VMPane runs). A failed create leaves nothing behind.
public struct VMCreator: Sendable {
    /// Everything the create needs, taken from the wizard on the main actor.
    public struct Request: Sendable {
        public var os: GuestOS
        public var name: String
        public var diskGiB: Int
        public var source: WizardModel.Source
        /// Windows only.
        public var unattend: UnattendInput?
        public var configure: @Sendable (inout VMConfigV1) -> Void
    }

    public enum Progress: Sendable, Equatable {
        case creating
        case downloading(received: Int64, total: Int64?)
        case preparing
    }

    let ops: LibraryOps
    let windowsTools: URL?

    public init(ops: LibraryOps, windowsTools: URL? = WindowsInstall.bundledTools()) {
        self.ops = ops
        self.windowsTools = windowsTools
    }

    public func create(_ request: Request, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> VMBundle {
        progress(.creating)
        let ops = ops
        let bundle = try await Blocking.run { try ops.create(name: request.name, os: request.os, diskGiB: request.diskGiB) }
        do {
            try await prepare(bundle, request, progress: progress)
            return bundle
        } catch {
            try? await Blocking.run { try ops.delete(bundle) }
            throw error
        }
    }

    private func prepare(_ bundle: VMBundle, _ request: Request, progress: @escaping @Sendable (Progress) -> Void) async throws {
        var config = try ConfigStore.load(bundle)
        request.configure(&config)
        let downloading: @Sendable (Int64, Int64?) -> Void = { progress(.downloading(received: $0, total: $1)) }
        // Downloads happen before the bundle is locked: they can take a long time.
        switch request.source {
        case .macCatalog(let image):
            let ipsw = try await ImageCache.ipsw.ensure(image, progress: downloading)
            config.install = Extensible(InstallConfig(restoreImage: ipsw.path))
        case .macRestoreImage(let url):
            config.install = Extensible(InstallConfig(restoreImage: url.path))
        case .linuxCatalog(let image):
            config = try await LinuxInstall.prepare(config, image: image, progress: downloading)
        case .linuxISO(let url):
            config = try LinuxInstall.prepare(config, iso: url)
        case .windowsISO:
            break
        }
        progress(.preparing)
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
            try ConfigStore.save(config, holding: lock)
        }
    }

    public enum CreateError: Error, Equatable, Sendable, CustomStringConvertible {
        case bundleBusy
        case missingAccount

        public var description: String {
            switch self {
            case .bundleBusy: "The new VM is in use by another process."
            case .missingAccount: "The Windows account is missing."
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
            configure: { wizard.configure(&$0) })
    }

    /// The settings `configure` writes, copied off the main actor.
    struct Snapshot: Sendable {
        let name: String, cpuCount: Int, memoryGiB: Int, audioOutput: Bool, microphone: Bool, clipboard: Bool
        let mcpPolicy: PolicyLevel, sharedFolders: [URL], rosetta: Bool, os: GuestOS?

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
        }

        func configure(_ config: inout VMConfigV1) {
            config.name = name.trimmingCharacters(in: .whitespaces)
            config.cpu.count = cpuCount
            config.memory.mib = memoryGiB << 10
            config.audio.output = audioOutput
            config.audio.input = microphone
            config.clipboard.mode = clipboard ? .both : .off
            config.mcp.policy = mcpPolicy
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
