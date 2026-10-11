import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

/// `vmpane install-cli`: a `vmpane` command on the PATH, as a symlink to this one (which stays valid across
/// updates of VMPane.app).
struct InstallCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cli",
        abstract: "Put vmpane on your PATH (/usr/local/bin, with one administrator prompt; --user: ~/.local/bin).")
    @Flag(help: "Install in ~/.local/bin, without an administrator prompt.") var user = false

    func run() throws {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        guard LaunchCoordinator.enclosingApp(of: executable) != nil else { CLI.fail("run the vmpane inside VMPane.app", .usage) }
        if user {
            let folder = MCPConfig.home.appendingPathComponent(".local/bin", isDirectory: true)
            let link = folder.appendingPathComponent("vmpane")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
            } catch {
                CLI.fail("cannot make \(link.path): \(error)", .failure)
            }
            print(
                "\(link.path) → \(executable.path)"
                    + ((ProcessInfo.processInfo.environment["PATH"] ?? "").contains(folder.path)
                        ? "" : "\n(add \(folder.path) to your PATH)"))
            return
        }
        // osascript's "with administrator privileges": the one system prompt (AuthorizationExecuteWithPrivileges is gone).
        let quoted = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        let shell = "mkdir -p /usr/local/bin && ln -sf '\(quoted)' /usr/local/bin/vmpane"
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { CLI.fail("not installed (the administrator prompt was cancelled?)", .failure) }
        print("/usr/local/bin/vmpane → \(executable.path)")
    }
}

/// `vmpane doctor`: whether VMPane's pieces are where and how they should be.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check VMPane's installation and running VMs.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        var checks: [JSONValue] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            checks.append(["check": .string(name), "ok": .bool(ok), "detail": .string(detail)])
        }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let app = LaunchCoordinator.enclosingApp(of: executable)
        check("app", app != nil, app?.path ?? "this vmpane is not inside VMPane.app")
        let paths = CLI.paths
        var info = stat()
        let folderPrivate = stat(paths.root.path, &info) == 0 && info.st_mode & 0o077 == 0
        check("VMPane folder", folderPrivate, "\(paths.root.path) " + (folderPrivate ? "(private)" : "is not 0700"))
        if let app {
            let version = RuntimeStore.version(app: app, appVersion: VMPane.version)
            let runtime = paths.root.appendingPathComponent("runtime/\(version)")
            check(
                "runtime copy", FileManager.default.fileExists(atPath: runtime.path),
                version + (FileManager.default.fileExists(atPath: runtime.path) ? "" : " not made yet (made when a VM starts)"))
            let qemu = app.appendingPathComponent("Contents/Helpers/qemu/bin/qemu-system-aarch64")
            check(
                "QEMU (Windows VMs)", FileManager.default.isExecutableFile(atPath: qemu.path),
                FileManager.default.isExecutableFile(atPath: qemu.path) ? "bundled" : "missing: Windows VMs cannot run")
        }
        let key = PolicyKeyFile(paths: paths).key(create: false) != nil
        check("agent policy key", true, key ? "present" : "not made yet (made when VMPane first runs)")
        check("agent kill switch", true, KillSwitch.isEngaged(paths: paths) ? "ENGAGED: AI agents are stopped" : "released")
        check("operator grant", true, OperatorGrant.isGranted(paths: paths) ? "granted (vmpane operator revoke)" : "not granted")
        let onPath = ["/usr/local/bin/vmpane", MCPConfig.home.appendingPathComponent(".local/bin/vmpane").path].first {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath() == executable
        }
        check("vmpane on PATH", true, onPath ?? "not installed (vmpane install-cli)")
        for item in (try? CLI.library.items()) ?? [] {
            let name = item.config?.name ?? item.bundle.url.lastPathComponent
            guard let session = try? await CLI.connector.connect(item.id) else { continue }
            let agent = try? await session.client.call(ControlMethod.agentStatus.rawValue, timeout: .seconds(3))
            session.client.close()
            let agentText = agent?["connected"] == true ? "agent \(agent?["version"]?.stringValue ?? "?")" : "no agent"
            check(
                "VM \(name)", session.helperVersion == VMPane.version,
                "helper \(session.helperVersion) (proto \(session.proto)), \(agentText)")
        }
        let allOK = checks.allSatisfy { $0["ok"] == true }
        CLI.print(.array(checks), json: output.json) {
            checks.map { "\($0["ok"] == true ? "✓" : "✗") \($0["check"]?.stringValue ?? ""): \($0["detail"]?.stringValue ?? "")" }.joined(
                separator: "\n")
        }
        if !allOK { throw ArgumentParser.ExitCode(ExitStatus.failure.rawValue) }
    }
}
