// The integration tests' stand-in for the app's policy controls, for helpers signed with a Developer ID: those
// never treat the itest bridge as the app (PeerClassifier), so the tests act as an agent would, within a policy
// set here the way the app sets it (VMPaneCore's PolicyIntegrity and KillSwitch). It writes only into the
// library named by $VMPANE_SUPPORT_DIR, a temporary one the test owns. Never shipped.
// It also stands in for the wizard's create of a Linux VM from a cloud image (VMCreator, as the app runs it).
// Usage: vmpane-itest-policy set <bundle> <off|observe|control|exec|admin> [--clipboard] [--confirm-exec]
//        vmpane-itest-policy release   (the kill switch)
//        vmpane-itest-policy create-cloud <image id> <name> <user> <qemu-img> <cache dir> [--desktop] [--ssh-key <key>]
//            (the password on stdin; prints the new bundle's path)
//        vmpane-itest-policy seed-omarchy <bundle> <user> [--ssh-key <key>]
//            (the password on stdin): OmarchyInstall.apply on a bundle whose config boots the Omarchy ISO as install media
import Foundation
import VMPaneCore
import VMPaneHost
import VMPaneUI

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("vmpane-itest-policy: \(message)\n".utf8))
    exit(code)
}

let usage =
    "usage: vmpane-itest-policy set <bundle> <level> [--clipboard] [--confirm-exec] | release "
    + "| create-cloud <image id> <name> <user> <qemu-img> <cache dir> [--desktop] [--ssh-key <key>] "
    + "| seed-omarchy <bundle> <user> [--ssh-key <key>]"
guard let support = ProcessInfo.processInfo.environment["VMPANE_SUPPORT_DIR"], !support.isEmpty else {
    fail("VMPANE_SUPPORT_DIR is not set (this tool never touches the real library)", code: 64)
}
let paths = VMPanePaths.standard()
let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "release":
        try KillSwitch.release(paths: paths)
    case "create-cloud":
        guard arguments.count >= 6, let image = try ImageCatalog.linux().images.first(where: { $0.id == arguments[1] }) else {
            fail(usage, code: 64)
        }
        let options = Array(arguments.dropFirst(6))
        let sshKey = options.firstIndex(of: "--ssh-key").flatMap { options.indices.contains($0 + 1) ? options[$0 + 1] : nil }
        let password =
            String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
        let account = CloudImageInstall.Account(
            userName: arguments[3], password: password, sshKey: sshKey, desktop: options.contains("--desktop"))
        let creator = VMCreator(
            ops: LibraryOps(library: VMLibrary(paths: paths), identity: .ui), windowsTools: nil,
            qemuImg: URL(fileURLWithPath: arguments[4]), cloudCache: ImageCache(directory: URL(fileURLWithPath: arguments[5])))
        let request = VMCreator.Request(
            os: .linux, name: arguments[2], diskGiB: 16, source: .linuxCatalog(image), cloudAccount: account
        ) { config in
            config.cpu.count = 2
            config.memory.mib = 4096
        }
        print(try await creator.create(request).url.path)
    case "seed-omarchy":
        let omarchy = try ImageCatalog.linux().images.first { $0.isAutoinstallISO && $0.distro == "omarchy" }
        guard arguments.count >= 3, let image = omarchy else { fail(usage, code: 64) }
        let options = Array(arguments.dropFirst(3))
        let sshKey = options.firstIndex(of: "--ssh-key").flatMap { options.indices.contains($0 + 1) ? options[$0 + 1] : nil }
        let password =
            String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
        let bundle = try VMBundle.open(URL(fileURLWithPath: arguments[1]))
        guard let lock = try bundle.tryLock() else { fail("a helper holds \(arguments[1]); stop it first") }
        defer { lock.release() }
        let config = try OmarchyInstall.apply(
            try ConfigStore.load(bundle), image: image, account: .init(userName: arguments[2], password: password, sshKey: sshKey),
            holding: lock)
        try ConfigStore.save(config, holding: lock)
    case "set":
        guard arguments.count >= 3, let level = PolicyLevel(rawValue: arguments[2]) else { fail(usage, code: 64) }
        let options = Set(arguments.dropFirst(3))
        guard options.isSubset(of: ["--clipboard", "--confirm-exec"]) else { fail(usage, code: 64) }
        let bundle = try VMBundle.open(URL(fileURLWithPath: arguments[1]))
        guard let key = PolicyKeyFile(paths: paths).key(create: true) else { fail("cannot make the policy key in \(support)") }
        var config = try ConfigStore.load(bundle)
        let confirmExec = options.contains("--confirm-exec")
        let clipboard = options.contains("--clipboard")
        // Already in effect: nothing to write (a restarted helper's children may still hold the lock meanwhile).
        let effective = PolicyIntegrity.effective(config, key: key)
        if effective.level == level, !effective.tampered, effective.clipboardAllowWithAgents == clipboard,
            config.mcp.confirmExec == confirmExec
        {
            exit(0)
        }
        config.mcp.policy = level
        config.mcp.confirmExec = confirmExec
        config.clipboard.allowWithAgents = clipboard
        // The helper holds the lock and its own copy of the config: change a VM's policy with its helper stopped.
        guard let lock = try bundle.tryLock() else { fail("a helper holds \(arguments[1]); stop it first") }
        try ConfigStore.save(PolicyIntegrity.signed(config, key: key), holding: lock)
    default:
        fail(usage, code: 64)
    }
} catch {
    fail("\(error)")
}
