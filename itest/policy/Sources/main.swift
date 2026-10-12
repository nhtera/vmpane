// The integration tests' stand-in for the app's policy controls, for helpers signed with a Developer ID: those
// never treat the itest bridge as the app (PeerClassifier), so the tests act as an agent would, within a policy
// set here the way the app sets it (VMPaneCore's PolicyIntegrity and KillSwitch). It writes only into the
// library named by $VMPANE_SUPPORT_DIR, a temporary one the test owns. Never shipped.
// Usage: vmpane-itest-policy set <bundle> <off|observe|control|exec|admin> [--clipboard] [--confirm-exec]
//        vmpane-itest-policy release   (the kill switch)
import Foundation
import VMPaneCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("vmpane-itest-policy: \(message)\n".utf8))
    exit(code)
}

let usage = "usage: vmpane-itest-policy set <bundle> <level> [--clipboard] [--confirm-exec] | release"
guard let support = ProcessInfo.processInfo.environment["VMPANE_SUPPORT_DIR"], !support.isEmpty else {
    fail("VMPANE_SUPPORT_DIR is not set (this tool never touches the real library)", code: 64)
}
let paths = VMPanePaths.standard()
let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "release":
        try KillSwitch.release(paths: paths)
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
