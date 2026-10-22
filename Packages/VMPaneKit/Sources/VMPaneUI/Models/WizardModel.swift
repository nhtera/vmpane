import Foundation
import Observation
import VMPaneCore
import VMPaneHost

/// The new-VM wizard's state and rules, without views: OS → source → resources → name → integrations →
/// summary. Each step validates on its own (`problems(in:)`); the views only show and edit this model.
@MainActor
@Observable
public final class WizardModel {
    public enum Step: Int, CaseIterable, Sendable {
        case os, source, account, resources, name, integrations, summary

        public var title: String {
            switch self {
            case .os: "System"
            case .source: "Installer"
            case .account: "Account"
            case .resources: "Resources"
            case .name: "Name"
            case .integrations: "Integrations"
            case .summary: "Summary"
            }
        }
    }

    /// Where the system comes from.
    public enum Source: Equatable, Sendable {
        /// macOS: a catalog restore image (downloaded and checked first).
        case macCatalog(ImageCatalog.Image)
        case macRestoreImage(URL)
        /// Linux: a catalog image (downloaded and checked first).
        case linuxCatalog(ImageCatalog.Image)
        case linuxISO(URL)
        /// Windows 11 ARM64 ISO the user downloaded from Microsoft.
        case windowsISO(URL)
    }

    /// What this Mac can give a VM.
    public struct Host: Sendable, Equatable {
        public var cores: Int
        public var memoryGiB: Int

        public init(cores: Int, memoryGiB: Int) {
            self.cores = cores
            self.memoryGiB = memoryGiB
        }

        public static var current: Host {
            Host(cores: ProcessInfo.processInfo.activeProcessorCount, memoryGiB: Int(ProcessInfo.processInfo.physicalMemory >> 30))
        }
    }

    public var step: Step = .os
    public var os: GuestOS? {
        didSet { if os != oldValue { applyDefaults() } }
    }
    public var source: Source?
    // Windows account (the password is held in memory only, cleared after create).
    public var userName = ""
    public var password = ""
    /// Keep the password so agents may sign the VM in (VM Settings › AI agents can change it later).
    public var keepSignInPassword = false
    public var edition = "Windows 11 Pro"
    public var eulaAccepted = false
    // Resources
    public var cpuCount = 4
    public var memoryGiB = 4
    public var diskGiB = 64
    // Name and integrations
    public var name = ""
    public var sharedFolders: [URL] = []
    public var clipboard = true
    public var audioOutput = true
    public var microphone = false
    public var rosetta = false
    /// What MCP clients may do with this VM; off until the user raises it (Phase 10 adds the warning flow).
    public var mcpPolicy: PolicyLevel = .off

    public let host: Host
    let existingNames: Set<String>

    public init(host: Host = .current, existingNames: some Sequence<String>) {
        self.host = host
        self.existingNames = Set(existingNames.map { $0.lowercased() })
        // macOS is chosen at the start, as the first card: Continue works at once (an observer does not run here).
        os = .macos
        applyDefaults()
    }

    /// Steps this OS goes through (only Windows asks for an account).
    public var steps: [Step] { Step.allCases.filter { $0 != .account || os == .windows } }

    /// Memory and CPU a Mac keeps for itself.
    public static let reservedHostMemoryGiB = 4
    /// Windows 11 refuses smaller disks.
    public static let windowsMinimumDiskGiB = 64

    public var maxMemoryGiB: Int { max(2, host.memoryGiB - Self.reservedHostMemoryGiB) }
    public var maxCPUs: Int { max(1, host.cores) }
    public var minDiskGiB: Int { os == .windows ? Self.windowsMinimumDiskGiB : 16 }

    private func applyDefaults() {
        guard let os else { return }
        source = nil
        cpuCount = min(4, maxCPUs)
        memoryGiB = min(os == .linux ? 4 : 8, maxMemoryGiB)
        diskGiB = os == .macos ? 80 : 64
        rosetta = false
        // A name the user typed stays; one the wizard suggested follows the system.
        if name.isEmpty || name == suggestedName {
            name = uniqueName(Self.defaultName(os))
            suggestedName = name
        }
    }

    /// The last name the wizard filled in itself.
    @ObservationIgnored private var suggestedName: String?

    static func defaultName(_ os: GuestOS) -> String {
        switch os {
        case .macos: "macOS"
        case .linux: "Linux"
        case .windows: "Windows 11"
        }
    }

    private func uniqueName(_ base: String) -> String {
        var candidate = base
        var suffix = 2
        while existingNames.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// What keeps `step` from being done; empty when it is.
    public func problems(in step: Step) -> [String] {
        switch step {
        case .os: os == nil ? ["Choose a system."] : []
        case .source: sourceProblems
        case .account: accountProblems
        case .resources: resourceProblems
        case .name: nameProblems
        case .integrations: rosetta && os != .linux ? ["Rosetta is for Linux guests."] : []
        case .summary: steps.filter { $0 != .summary }.flatMap { problems(in: $0) }
        }
    }

    private var sourceProblems: [String] {
        switch (os, source) {
        case (_, nil): ["Choose where the system comes from."]
        case (.macos?, .macCatalog?), (.macos?, .macRestoreImage?), (.linux?, .linuxCatalog?), (.linux?, .linuxISO?),
            (.windows?, .windowsISO?):
            []
        default: ["That installer is not for this system."]
        }
    }

    private var accountProblems: [String] {
        guard os == .windows else { return [] }
        var problems: [String] = []
        let user = userName.trimmingCharacters(in: .whitespaces)
        if user.isEmpty { problems.append("Enter a user name.") }
        if user.count > 20 || user.contains(where: { "\\/[]:;|=,+*?<>\"@".contains($0) }) {
            problems.append("User names have at most 20 characters and none of \\ / [ ] : ; | = , + * ? < > \" @.")
        }
        if ["administrator", "guest", "defaultaccount"].contains(user.lowercased()) {
            problems.append("\(user) is reserved by Windows.")
        }
        if password.count < 4 { problems.append("Use a password of at least 4 characters.") }
        if !eulaAccepted { problems.append("Accept Microsoft's licence terms to install Windows.") }
        return problems
    }

    private var resourceProblems: [String] {
        var problems: [String] = []
        if !(1...maxCPUs).contains(cpuCount) { problems.append("Use 1 to \(maxCPUs) processors.") }
        if !(2...maxMemoryGiB).contains(memoryGiB) {
            problems.append("Use 2 to \(maxMemoryGiB) GB of memory (this Mac keeps \(Self.reservedHostMemoryGiB) GB).")
        }
        if diskGiB < minDiskGiB { problems.append("Use a disk of at least \(minDiskGiB) GB.") }
        return problems
    }

    private var nameProblems: [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ["Enter a name."] }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.hasPrefix(".") {
            return ["Names cannot contain / or : or start with a dot."]
        }
        if existingNames.contains(trimmed.lowercased()) { return ["A VM named \(trimmed) exists already."] }
        return []
    }

    public func canLeave(_ step: Step) -> Bool { problems(in: step).isEmpty }

    public func next() {
        guard canLeave(step), let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    public func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    /// The VM's settings from the wizard (the install media are added by `VMCreator`).
    public func configure(_ config: inout VMConfigV1) {
        Snapshot(self).configure(&config)
    }

    /// A Windows computer name from the VM's name: letters, digits and hyphens, at most 15, not all digits.
    nonisolated static func computerName(from name: String) -> String {
        let allowed = name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var result = String(allowed).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        result = String(result.prefix(15))
        if result.isEmpty || result.allSatisfy(\.isNumber) { result = "VMPANE-" + String(result.prefix(8)) }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Forgets the Windows password (after create, or when the wizard closes).
    public func clearSecrets() {
        password = ""
    }
}
