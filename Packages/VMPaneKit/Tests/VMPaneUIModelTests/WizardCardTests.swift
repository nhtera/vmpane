import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost
@testable import VMPaneUI

private let catalogs = WizardModel.Catalogs(
    macOS: [image("macos-15", "macOS Sequoia 15.6.1", "15.6.1")],
    linux: [
        image("ubuntu-server", "Ubuntu Server 24.04.5", "24.04.5"), image("ubuntu-cloud", "Ubuntu 26.04", "26.04", distro: "ubuntu"),
        image("debian-cloud", "Debian 13", "13", distro: "debian"), image("fedora-cloud", "Fedora 44", "44", distro: "fedora"),
    ])

private func image(_ id: String, _ name: String, _ version: String, distro: String? = nil) -> ImageCatalog.Image {
    var image = ImageCatalog.Image(
        id: id, name: name, version: version, url: URL(fileURLWithPath: "/tmp/\(id)"), sha256: String(repeating: "0", count: 64),
        sizeBytes: 1)
    if let distro {
        image.kind = "cloudImage"
        image.distro = distro
    }
    return image
}

/// ⌘N, Return: an Ubuntu card makes a VM with nothing else typed (an account of the Mac's user name, a made-up
/// password kept for the person), sized for this Mac.
@MainActor @Test func aLinuxCardIsReadyToCreate() throws {
    let wizard = WizardModel(host: .init(cores: 10, memoryGiB: 16), existingNames: ["Ubuntu 26.04"])
    wizard.choose(.ubuntu, catalogs: catalogs)
    #expect(wizard.os == .linux && wizard.isCloudImage && wizard.card == .ubuntu)
    #expect(wizard.problems(in: .summary).isEmpty, "\(wizard.problems(in: .summary))")
    #expect(!wizard.keepSignInPassword && wizard.password.count == 16 && wizard.generatedAccountNote != nil)
    #expect(wizard.name == "Ubuntu 26.04 2", "a free name")
    #expect(wizard.summaryLine == "Ubuntu 26.04 Server · 4 CPUs · 4 GB · 64 GB · Agents: Off")
    let request = try #require(wizard.request())
    #expect(request.cloudAccount?.password == wizard.password && request.keepPassword, "kept for Copy Password")
    var config = VMConfigV1(VMConfigFields.new(name: "x", os: .linux, diskGiB: 8, macAddress: "02:00:00:00:00:01"))
    request.configure(&config)
    #expect(config.mcp.signIn != true, "agents may not sign in unless the person allows it")
    wizard.desktop = true
    #expect(wizard.memoryGiB == 8 && wizard.summaryLine.hasPrefix("Ubuntu 26.04 Desktop"))
    wizard.choose(.fedora, catalogs: catalogs)
    #expect(wizard.summaryLine.hasPrefix("Fedora 44 Server") && wizard.name == "Fedora 44" && !wizard.desktop)
    wizard.choose(.windows, catalogs: catalogs)
    #expect(wizard.password.isEmpty && !wizard.usesGeneratedPassword, "a made-up password does not follow to Windows")
}

@MainActor @Test func macOSIsReadyAndWindowsWaitsForItsISO() {
    let wizard = WizardModel(host: .init(cores: 10, memoryGiB: 16), existingNames: [])
    wizard.choose(.macos, catalogs: catalogs)
    #expect(wizard.problems(in: .summary).isEmpty && wizard.memoryGiB == 8 && wizard.diskGiB == 80)
    wizard.choose(.windows, catalogs: catalogs)
    #expect(wizard.problems(in: .summary).first == "Choose where the system comes from.")
    wizard.use(URL(fileURLWithPath: "/tmp/Win11_ARM64.iso"), kind: .windowsISO)
    #expect(wizard.source == .windowsISO(URL(fileURLWithPath: "/tmp/Win11_ARM64.iso")) && wizard.card == .windows)
}

/// Defaults follow the Mac: at most half its processors and memory, at least what the system needs.
@MainActor @Test func defaultsAreSizedForTheMac() {
    let small = WizardModel(host: .init(cores: 8, memoryGiB: 8), existingNames: [])
    small.choose(.windows, catalogs: catalogs)
    #expect(small.cpuCount == 4 && small.memoryGiB == 4, "8 GB Mac: Windows gets its minimum")
    small.choose(.ubuntu, catalogs: catalogs)
    #expect(small.memoryGiB == 4)
    let big = WizardModel(host: .init(cores: 16, memoryGiB: 64), existingNames: [])
    big.choose(.macos, catalogs: catalogs)
    #expect(big.cpuCount == 4 && big.memoryGiB == 8)
}

@Test func theMacsUserNameBecomesTheLinuxUser() {
    #expect(WizardModel.defaultUserName("Tien Nguyen") == "tiennguyen")
    #expect(WizardModel.defaultUserName("root") == "user")
    #expect(WizardModel.defaultUserName("4you") == "user")
    #expect(Set((0..<20).map { _ in WizardModel.generatedPassword() }).count == 20)
}

/// Dropped installers: the kind from the inspectors' verdicts, with the messages the sheet shows.
@Test func installersAreRecognisedOrRefused() throws {
    #expect(try InstallMediaKind.kind(windows: .windows11(editions: [])) { .unreadable } == .windowsISO)
    #expect(try InstallMediaKind.kind(windows: .notWindows) { .arm64 } == .linuxISO)
    #expect(throws: InstallMediaKind.Refusal.x64Windows) { try InstallMediaKind.kind(windows: .notArm64) { .arm64 } }
    #expect(throws: InstallMediaKind.Refusal.olderWindows(build: 19045)) {
        try InstallMediaKind.kind(windows: .notWindows11(build: 19045)) { .arm64 }
    }
    #expect(throws: InstallMediaKind.Refusal.x64Linux) { try InstallMediaKind.kind(windows: .notWindows) { .notArm64 } }
    #expect(InstallMediaKind.Refusal.x64Windows.description == "This is an x64 ISO. VMPane needs Windows 11 for Arm (ARM64).")
    #expect(try InstallMediaKind.detect(URL(fileURLWithPath: "/tmp/UniversalMac_15.6.1_24G90_Restore.ipsw")) == .macRestoreImage)
    #expect(throws: InstallMediaKind.Refusal.notAnInstaller) { try InstallMediaKind.detect(URL(fileURLWithPath: "/tmp/a.dmg")) }
}

/// The sheet lists the cards in sections, macOS first; each row says the version Create makes.
@Test func cardsAreGroupedAndSayTheirVersion() {
    #expect(WizardModel.CardGroup.allCases.map(\.cards) == [[.macos], [.ubuntu, .debian, .fedora], [.windows]])
    #expect(WizardModel.Card.allCases.map { $0.versionText(in: catalogs) } == ["Sequoia 15.6.1", "26.04", "13", "44", "11 for Arm"])
    #expect(WizardModel.Card.ubuntu.images(in: catalogs).map(\.id) == ["ubuntu-cloud"], "cloud images only")
    #expect(WizardModel.Card.windows.images(in: catalogs).isEmpty)
    #expect(WizardModel.Card.fedora.versionText(in: .init(macOS: [], linux: [])) == nil, "no image, no version")
}

/// The bundled catalog's rows read as the design shows them.
@Test func theBundledCatalogsVersions() {
    #expect(WizardModel.Card.ubuntu.versionText(in: .bundled) == "26.04 LTS")
    #expect(WizardModel.Card.macos.versionText(in: .bundled)?.hasPrefix("Sequoia") == true)
}

/// The version picker: another image of the chosen card replaces the source and the suggested name, nothing else.
@MainActor @Test func anotherVersionKeepsTheRestOfTheChoice() {
    let older = image("macos-14", "macOS Sonoma 14.7", "14.7")
    let both = WizardModel.Catalogs(macOS: [older] + catalogs.macOS, linux: catalogs.linux)
    let wizard = WizardModel(host: .init(cores: 10, memoryGiB: 16), existingNames: [])
    wizard.choose(.macos, catalogs: both)
    #expect(wizard.catalogImage?.id == "macos-15" && wizard.name == "macOS Sequoia 15.6.1", "the newest first")
    wizard.cpuCount = 2
    wizard.pick(older)
    #expect(wizard.source == .macCatalog(older) && wizard.name == "macOS Sonoma 14.7" && wizard.cpuCount == 2)
    #expect(WizardModel.Card.macos.images(in: both).count == 2)
    wizard.choose(.windows, catalogs: both)
    wizard.pick(older)
    #expect(wizard.source == nil, "Windows has no catalog image")
}
