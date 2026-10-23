import Foundation
import VMPaneCore
import VMPaneHost

/// The new-VM sheet's front: one card per system, sized for this Mac, and a line saying what Create makes.
extension WizardModel {
    public enum Card: String, CaseIterable, Identifiable, Sendable {
        case macos, ubuntu, debian, fedora, windows

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .macos: "macOS"
            case .ubuntu: "Ubuntu"
            case .debian: "Debian"
            case .fedora: "Fedora"
            case .windows: "Windows 11"
            }
        }

        public var os: GuestOS {
            switch self {
            case .macos: .macos
            case .ubuntu, .debian, .fedora: .linux
            case .windows: .windows
            }
        }

        /// What Create does, in a sentence or two (the new-VM sheet's detail).
        public var about: String {
            switch self {
            case .macos: "Apple’s restore image, downloaded and installed for you. You finish in macOS Setup Assistant."
            case .ubuntu, .debian, .fedora:
                "A cloud image: nothing to click through. SSH on 127.0.0.1 and the guest tools are ready on the first boot."
            case .windows: "Installed for you from Microsoft’s Windows 11 for Arm ISO, with no clicks, in about 10 minutes."
            }
        }

        /// A Linux card's cloud image in the catalog (`distro`).
        var distro: String? { os == .linux ? rawValue : nil }

        public var group: CardGroup {
            switch os {
            case .macos: .macos
            case .linux: .linux
            case .windows: .windows
            }
        }

        /// The images Create can make the card from: all of macOS's restore images, a distribution's cloud images
        /// (none for Windows: Microsoft's ISO). `choose` takes the newest; a picker is worth showing only for more
        /// than one.
        public func images(in catalogs: Catalogs) -> [ImageCatalog.Image] {
            switch self {
            case .macos: catalogs.macOS
            case .ubuntu, .debian, .fedora: catalogs.linux.filter { $0.isCloudImage && $0.distro == distro }
            case .windows: []
            }
        }

        /// The version a list row shows under the title ("26.04 LTS", "Sequoia 15.6.1", "11 for Arm"): the image
        /// `choose` takes, without the name the title already says.
        public func versionText(in catalogs: Catalogs) -> String? {
            switch self {
            case .macos:
                return catalogs.macOS.last.map { Self.dropping("macOS", from: $0.title) }
            case .ubuntu, .debian, .fedora:
                return images(in: catalogs).first.map { Self.dropping(title, from: $0.title) }
            case .windows:
                return "11 for Arm"
            }
        }

        /// `title` without a leading `name` ("macOS Sequoia 15.6.1" → "Sequoia 15.6.1").
        public static func dropping(_ name: String, from title: String) -> String {
            guard title.hasPrefix(name + " ") else { return title }
            return String(title.dropFirst(name.count + 1))
        }
    }

    /// The new-VM sheet's sections, in order. Installer files from this Mac are a row of their own, after them.
    public enum CardGroup: String, CaseIterable, Identifiable, Sendable {
        case macos = "macOS", linux = "Linux", windows = "Windows"

        public var id: String { rawValue }
        public var cards: [Card] { Card.allCases.filter { $0.group == self } }
    }

    /// What a system needs, and what VMPane gives it on a Mac with room (`sized` fits it to this Mac).
    public struct Recommended: Equatable, Sendable {
        public var cpus: Int
        public var memoryGiB: Int
        public var minimumMemoryGiB: Int
        public var diskGiB: Int

        public static func `for`(_ os: GuestOS, desktop: Bool = false) -> Recommended {
            switch os {
            case .macos: Recommended(cpus: 4, memoryGiB: 8, minimumMemoryGiB: 4, diskGiB: 80)
            case .linux where desktop: Recommended(cpus: 4, memoryGiB: 8, minimumMemoryGiB: 4, diskGiB: 64)
            case .linux: Recommended(cpus: 4, memoryGiB: 4, minimumMemoryGiB: 2, diskGiB: 64)
            case .windows: Recommended(cpus: 4, memoryGiB: 8, minimumMemoryGiB: 4, diskGiB: 64)
            }
        }
    }

    /// `recommended` on this Mac: at most half its processors and memory (and what it can spare), at least the minimum.
    func sized(_ recommended: Recommended) -> (cpus: Int, memoryGiB: Int) {
        let cpus = min(recommended.cpus, max(2, host.cores / 2), maxCPUs)
        let memory = min(recommended.memoryGiB, max(recommended.minimumMemoryGiB, host.memoryGiB / 2), maxMemoryGiB)
        return (cpus, memory)
    }

    /// Chooses `card`: its system, its installer when VMPane can fetch it, and for a Linux cloud image an account
    /// (this Mac's user name and a generated password, kept for agent sign-in and Copy Password).
    public func choose(_ card: Card, catalogs: Catalogs = .bundled) {
        // A password made up for another card is not carried over (nobody would know it).
        if usesGeneratedPassword { password = "" }
        generatedPassword = nil
        self.card = card
        os = card.os
        applyDefaults()
        switch card {
        case .macos:
            source = catalogs.macOS.last.map { .macCatalog($0) }
        case .ubuntu, .debian, .fedora:
            source = catalogs.linux.first { $0.isCloudImage && $0.distro == card.distro }.map { .linuxCatalog($0) }
            userName = Self.defaultUserName()
            let password = Self.generatedPassword()
            self.password = password
            generatedPassword = password
        case .windows:
            break  // Microsoft's ISO: the person downloads it (Customize)
        }
        rename(Self.defaultName(card, source: source))
    }

    /// Another of the card's catalog images (the version picker); the rest of the choice stays.
    public func pick(_ image: ImageCatalog.Image) {
        guard let card else { return }
        switch card.os {
        case .macos: source = .macCatalog(image)
        case .linux: source = .linuxCatalog(image)
        case .windows: return
        }
        rename(Self.defaultName(card, source: source))
    }

    /// The catalog image Create makes the VM from (nil: an installer file, or Windows).
    public var catalogImage: ImageCatalog.Image? {
        switch source {
        case .macCatalog(let image)?, .linuxCatalog(let image)?: image
        default: nil
        }
    }

    /// The installer file from this Mac Create makes the VM from (nil: a catalog image, or none yet).
    public var installerFile: URL? {
        switch source {
        case .macRestoreImage(let url)?, .linuxISO(let url)?, .windowsISO(let url)?: url
        default: nil
        }
    }

    /// A dropped installer (`InstallMediaKind`): its system and the file, ready to finish in Customize.
    public func use(_ media: URL, kind: InstallMediaKind) {
        switch kind {
        case .macRestoreImage:
            choose(.macos, catalogs: Catalogs(macOS: [], linux: []))
            source = .macRestoreImage(media)
        case .linuxISO:
            card = nil
            os = .linux
            applyDefaults()
            source = .linuxISO(media)
        case .windowsISO:
            choose(.windows, catalogs: Catalogs(macOS: [], linux: []))
            source = .windowsISO(media)
        }
    }

    /// The catalogs the cards fetch from.
    public struct Catalogs: Sendable {
        public var macOS: [ImageCatalog.Image]
        public var linux: [ImageCatalog.Image]

        public init(macOS: [ImageCatalog.Image], linux: [ImageCatalog.Image]) {
            self.macOS = macOS
            self.linux = linux
        }

        public static let bundled = Catalogs(
            macOS: (try? ImageCatalog.macOS().images) ?? [], linux: (try? ImageCatalog.linux().images) ?? [])
    }

    /// What Create makes, in one line ("Ubuntu 26.04 Server · 4 CPUs · 4 GB · 64 GB · Agents: Off").
    public var summaryLine: String {
        let system: String =
            switch source {
            case .macCatalog(let image)?: image.title
            case .linuxCatalog(let image)?: image.isCloudImage ? "\(image.title) \(desktop ? "Desktop" : "Server")" : image.title
            case .macRestoreImage(let url)?, .linuxISO(let url)?, .windowsISO(let url)?: url.lastPathComponent
            case nil: card?.title ?? os.map(Self.defaultName) ?? "A VM"
            }
        return [system, "\(cpuCount) CPUs", "\(memoryGiB) GB", "\(diskGiB) GB", "Agents: \(mcpPolicy.title)"]
            .joined(separator: " · ")
    }

    /// The password in use is the one VMPane made up (kept for the person: Copy Password).
    public var usesGeneratedPassword: Bool { generatedPassword.map { $0 == password } ?? false }

    /// This Mac's short user name when it suits Linux, else "user".
    nonisolated static func defaultUserName(_ macUser: String = NSUserName()) -> String {
        let name = String(macUser.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }.prefix(32))
        guard CloudInitSeed.isUserName(name), !CloudInitSeed.reservedNames.contains(name), !name.hasPrefix("systemd-") else {
            return "user"
        }
        return name
    }

    /// 16 characters, easy to read and type (no 0/O, 1/l/I).
    nonisolated static func generatedPassword() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    static func defaultName(_ card: Card, source: Source?) -> String {
        switch source {
        case .macCatalog(let image)?, .linuxCatalog(let image)?: image.title
        default: card.title
        }
    }
}
