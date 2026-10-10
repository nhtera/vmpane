import AppKit
import VMPaneCore
import VMPaneHost
import VMPaneVZ

/// Per-VM helper app: one process per running VM, with its own Dock tile and window.
/// Usage: VMPaneVM --vm <bundle> [--headless]
@main
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var controller: HelperController?
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let arguments = HelperArguments(CommandLine.arguments)
        if let arguments, arguments.validateOnly {
            // Checks the VM's configuration with the real entitlement (integration tests), then exits.
            do {
                try BackendFactory.validate(try VMBundle.open(arguments.bundle))
                print("VMPaneVM: configuration valid")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("VMPaneVM: configuration invalid: \(error)\n".utf8))
                exit(1)
            }
        }
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
        let controller = makeController(prepared)
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

extension HelperDelegate {
    /// Shows the VM's window when it starts (unless headless) or when `vm.display.show` asks for it.
    fileprivate func observeDisplay(_ controller: HelperController, backend: VZBackend, config: VMConfigV1) {
        let headless = arguments.headless
        Task { @MainActor in
            for await state in controller.stateChanges where state == .running && !headless {
                backend.showDisplay()
            }
        }
        Task { @MainActor in
            for await _ in controller.displayRequests { backend.showDisplay() }
        }
    }
}

extension HelperDelegate {
    /// Integration-test hook (S11 matrix): once the VM runs and `<output>.go` exists, tries each runtime
    /// change and writes the results to `<output>` as JSON.
    fileprivate func probeLiveChanges(_ controller: HelperController, backend: VZBackend, output: URL) {
        Task { @MainActor in
            for await state in controller.stateChanges where state == .running {
                let trigger = output.appendingPathExtension("go")
                while !FileManager.default.fileExists(atPath: trigger.path) {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                let results = await backend.probeLiveChanges(scratch: output.deletingLastPathComponent())
                let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                try? data?.write(to: output, options: .atomic)
                return
            }
        }
    }
}

extension HelperDelegate {
    /// Chooses the backend (saving first-start config changes) and builds the controller.
    fileprivate func makeController(_ prepared: PreparedBundle) -> HelperController {
        let made: BackendFactory.Made
        do {
            made = try BackendFactory.make(prepared)
        } catch {
            FileHandle.standardError.write(Data("VMPaneVM: cannot prepare the VM: \(error)\n".utf8))
            made = BackendFactory.Made(backend: nil, config: prepared.config)
        }
        let controller = HelperController(
            prepared: prepared, runtimeVersion: VMPane.version, backend: made.backend, config: made.config,
            afterStart: made.afterStart, afterStop: made.afterStop
        ) {
            DispatchQueue.main.async { exit(0) }
        }
        self.controller = controller
        if let vz = made.backend as? VZBackend {
            observeDisplay(controller, backend: vz, config: made.config)
            if let output = ProcessInfo.processInfo.environment["VMPANE_TEST_PROBE_LIVE"] {
                probeLiveChanges(controller, backend: vz, output: URL(fileURLWithPath: output))
            }
        }
        return controller
    }
}

struct HelperArguments {
    let bundle: URL
    let headless: Bool
    let validateOnly: Bool

    /// Parses `--vm <path>`, `--headless` and `--validate-config`; ignores what LaunchServices adds
    /// (e.g. `-psn_…`).
    init?(_ argv: [String]) {
        guard let index = argv.firstIndex(of: "--vm"), argv.indices.contains(index + 1) else { return nil }
        bundle = URL(fileURLWithPath: argv[index + 1])
        headless = argv.contains("--headless")
        validateOnly = argv.contains("--validate-config")
    }
}
