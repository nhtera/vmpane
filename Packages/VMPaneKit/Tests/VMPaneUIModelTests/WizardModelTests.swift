import Foundation
import Testing
import VMPaneCore
import VMPaneHost

@testable import VMPaneUI

private let mac = WizardModel.Host(cores: 10, memoryGiB: 16)

@Test @MainActor func defaultsFollowTheChosenSystem() {
    let wizard = WizardModel(host: mac, existingNames: ["Linux"])
    wizard.os = .linux
    #expect((wizard.cpuCount, wizard.memoryGiB, wizard.diskGiB) == (4, 4, 64))
    #expect(wizard.name == "Linux 2", "the default name avoids existing VMs")
    wizard.os = .windows
    #expect((wizard.memoryGiB, wizard.diskGiB, wizard.name) == (8, 64, "Windows 11"))
    #expect(wizard.steps.contains(.account))
    wizard.os = .macos
    #expect((wizard.memoryGiB, wizard.diskGiB) == (8, 80))
    #expect(!wizard.steps.contains(.account))
    wizard.name = "My Mac"
    wizard.os = .linux
    #expect(wizard.name == "My Mac", "a name the user typed stays")
}

@Test @MainActor func resourcesStayWithinWhatTheMacHas() {
    let wizard = WizardModel(host: mac, existingNames: [])
    wizard.os = .linux
    #expect(wizard.canLeave(.resources))
    wizard.memoryGiB = 13  // 16 GB Mac keeps 4
    #expect(wizard.problems(in: .resources).count == 1)
    wizard.memoryGiB = 12
    wizard.cpuCount = 11
    #expect(!wizard.canLeave(.resources))
    wizard.cpuCount = 10
    wizard.os = .windows
    wizard.diskGiB = 63
    #expect(wizard.problems(in: .resources) == ["Use a disk of at least 64 GB."])
}

@Test @MainActor func namesMustBeUniqueAndUsable() {
    let wizard = WizardModel(host: mac, existingNames: ["Dev Box"])
    wizard.os = .linux
    for bad in ["", "   ", "a/b", "x:y", ".hidden", "dev box"] {
        wizard.name = bad
        #expect(!wizard.canLeave(.name), "\(bad)")
    }
    wizard.name = "Dev Box 2"
    #expect(wizard.canLeave(.name))
}

@Test @MainActor func theInstallerMustMatchTheSystem() {
    let wizard = WizardModel(host: mac, existingNames: [])
    wizard.os = .linux
    #expect(!wizard.canLeave(.source))
    wizard.source = .windowsISO(URL(fileURLWithPath: "/tmp/win.iso"))
    #expect(wizard.problems(in: .source) == ["That installer is not for this system."])
    wizard.source = .linuxISO(URL(fileURLWithPath: "/tmp/ubuntu.iso"))
    #expect(wizard.canLeave(.source))
    wizard.os = .macos
    #expect(wizard.source == nil, "a new system clears the installer")
}

@Test @MainActor func windowsNeedsAnAccountAndTheLicence() {
    let wizard = WizardModel(host: mac, existingNames: [])
    wizard.os = .windows
    #expect(wizard.problems(in: .account).count == 3)  // user, password, licence
    wizard.userName = "Administrator"
    wizard.password = "pw"
    #expect(wizard.problems(in: .account).contains("Administrator is reserved by Windows."))
    wizard.userName = "tien"
    wizard.password = "secret1"
    wizard.eulaAccepted = true
    #expect(wizard.canLeave(.account))
    wizard.source = .windowsISO(URL(fileURLWithPath: "/tmp/win.iso"))
    let request = wizard.request(locale: Locale(identifier: "vi_VN"), now: Date(timeIntervalSince1970: 1))
    #expect(request != nil)
    #expect(request?.unattend?.userName == "tien")
    #expect(request?.unattend?.locale == "vi-VN")
    #expect(request?.unattend?.eulaAcceptedAt == Date(timeIntervalSince1970: 1))
    wizard.clearSecrets()
    #expect(wizard.password.isEmpty)
}

@Test @MainActor func nextStopsAtTheFirstUnfinishedStep() {
    let wizard = WizardModel(host: mac, existingNames: [])
    wizard.next()
    #expect(wizard.step == .os)
    wizard.os = .linux
    wizard.next()
    #expect(wizard.step == .source)
    wizard.next()
    #expect(wizard.step == .source)
    wizard.source = .linuxISO(URL(fileURLWithPath: "/tmp/x.iso"))
    wizard.next()
    #expect(wizard.step == .resources, "Linux skips the account step")
    wizard.back()
    #expect(wizard.step == .source)
    #expect(wizard.request() == nil || wizard.canLeave(.summary))
}

@Test @MainActor func configureWritesTheChoices() throws {
    let wizard = WizardModel(host: mac, existingNames: [])
    wizard.os = .linux
    wizard.cpuCount = 6
    wizard.memoryGiB = 8
    wizard.clipboard = false
    wizard.rosetta = true
    wizard.sharedFolders = [URL(fileURLWithPath: "/Users/a/Documents"), URL(fileURLWithPath: "/Volumes/X/Documents")]
    var config = VMConfigV1(VMConfigFields.new(name: "x", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    wizard.configure(&config)
    #expect(config.cpu.count == 6 && config.memory.mib == 8192)
    #expect(config.clipboard.mode == .off)
    #expect(config.mcp.policy == .off)
    #expect(config.shares.map(\.name) == ["Documents", "Documents 2"])
    #expect(config.vz?.rosetta == true)
}

@Test func windowsComputerNamesAreValid() {
    #expect(WizardModel.computerName(from: "Windows 11") == "Windows-11")
    #expect(WizardModel.computerName(from: "Máy ảo của tôi dài quá") == "M-y-o-c-a-t-i-d")
    #expect(WizardModel.computerName(from: "2024") == "VMPANE-2024")
}

@Test @MainActor func creatorBuildsTheVMOrLeavesNothing() async throws {
    let root = URL(fileURLWithPath: "/tmp/vp-wz-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = VMLibrary(paths: VMPanePaths(root: root))
    let creator = VMCreator(ops: LibraryOps(library: library, identity: .ui), windowsTools: nil)

    let wizard = WizardModel(host: mac, existingNames: [])
    wizard.os = .macos
    wizard.name = "Sequoia"
    wizard.source = .macRestoreImage(URL(fileURLWithPath: "/tmp/UniversalMac.ipsw"))
    let bundle = try await creator.create(try #require(wizard.request()))
    let config = try ConfigStore.load(bundle)
    #expect(config.name == "Sequoia" && config.memory.mib == 8192)
    #expect(config.install?.restoreImage == "/tmp/UniversalMac.ipsw")

    // A Linux "ISO" that is not one: the create fails and its bundle is gone again.
    let notAnISO = root.appendingPathComponent("junk.iso")
    try Data("not an iso".utf8).write(to: notAnISO)
    wizard.os = .linux
    wizard.name = "Broken"
    wizard.source = .linuxISO(notAnISO)
    await #expect(throws: LinuxInstallError.self) { try await creator.create(try #require(wizard.request())) }
    #expect(try library.items().map { $0.config?.name } == ["Sequoia"])
}
