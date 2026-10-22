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

        /// What the card makes, in a few words.
        public var detail: String {
            switch self {
            case .macos: "Apple's latest restore image"
            case .ubuntu, .debian, .fedora: "Ready in minutes, SSH and guest tools set up"
            case .windows: "Windows 11 for Arm, installed for you from Microsoft's ISO"
            }
        }

        /// A Linux card's cloud image in the catalog (`distro`).
        var distro: String? { os == .linux ? rawValue : nil }
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

    /// The account line for a cloud image whose password VMPane made up (nil otherwise).
    public var generatedAccountNote: String? {
        guard isCloudImage, usesGeneratedPassword else { return nil }
        return "Account \(userName), with a password VMPane keeps for you (Copy Password in the VM's inspector)."
    }

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
