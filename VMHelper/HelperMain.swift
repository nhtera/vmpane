import AppKit
import VMPaneCore
import VMPaneHost

/// Per-VM helper app: one process per running VM, with its own Dock tile and window.
/// Usage: VMPaneVM --vm <bundle> [--headless]
@main
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var controller: HelperController?
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let arguments = HelperArguments(CommandLine.arguments)
        guard let arguments else {
            FileHandle.standardError.write(Data("usage: VMPaneVM --vm <bundle> [--headless]\n".utf8))
            exit(64)  // EX_USAGE
        }
        let app = NSApplication.shared
        app.setActivationPolicy(arguments.headless ? .accessory : .regular)
        let delegate = HelperDelegate(arguments: arguments)
        app.delegate = delegate
        app.run()
    }

    private let arguments: HelperArguments

    init(arguments: HelperArguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Signals first: a SIGTERM during start-up must not kill the helper half-way through preparing.
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let controller = self?.controller else { exit(0) }  // nothing owned yet
                Task { await controller.shutdown() }
            }
            source.resume()
            signalSources.append(source)
        }
        let paths = VMPanePaths.standard()
        RunDirectoryReconciler.reconcile(paths: paths)
        let prepared: PreparedBundle
        do {
            let bundle = try VMBundle.open(arguments.bundle)
            prepared = try LaunchCoordinator.prepareBundle(
                bundle, paths: paths, runtimeVersion: VMPane.version,
                library: VMLibrary(paths: paths))
        } catch LaunchError.alreadyRunning {
            exit(LaunchCoordinator.alreadyRunningExitCode)
        } catch {
            FileHandle.standardError.write(Data("VMPaneVM: cannot open \(arguments.bundle.path): \(error)\n".utf8))
            exit(1)
        }
        if ProcessInfo.processInfo.environment["VMPANE_TEST_DUMMY_CHILD"] == "1" {
            // Integration-test hook: a child that holds the bundle lock like a disk writer would.
            let registry = ChildProcessRegistry(runFiles: prepared.runFiles, owner: prepared.owner)
            _ = try? registry.spawn(
                URL(fileURLWithPath: "/bin/sleep"), .init(arguments: ["3600"], inheriting: [prepared.lock.fileDescriptor]))
        }
        let controller = HelperController(prepared: prepared, runtimeVersion: VMPane.version, backend: nil) {
            DispatchQueue.main.async { exit(0) }
        }
        self.controller = controller
        Task {
            do {
                try await controller.start()
            } catch {
                FileHandle.standardError.write(Data("VMPaneVM: cannot bind the control socket: \(error)\n".utf8))
                await controller.shutdown()
            }
        }
    }
}

struct HelperArguments {
    let bundle: URL
    let headless: Bool

    /// Parses `--vm <path>` and `--headless`; ignores what LaunchServices adds (e.g. `-psn_…`).
    init?(_ argv: [String]) {
        guard let index = argv.firstIndex(of: "--vm"), argv.indices.contains(index + 1) else { return nil }
        bundle = URL(fileURLWithPath: argv[index + 1])
        headless = argv.contains("--headless")
    }
}
