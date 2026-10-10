import AppKit
import VMPaneCore
import VMPaneHost
import VMPaneQEMU
import VMPaneSpice
import VMPaneVZ
import os

/// Per-VM helper app: one process per running VM, with its own Dock tile and window.
/// Usage: VMPaneVM --vm <bundle> [--headless]
@main
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var controller: HelperController?
    private var signalSources: [DispatchSourceSignal] = []
    /// Shows the VM's window (set once the display exists). Closing the window only hides it: the VM keeps running.
    private var showWindow: (@MainActor () -> Void)?

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

    /// A click on the Dock tile brings a closed window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, !arguments.headless { MainActor.assumeIsolated { showWindow?() } }
        return true
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
        let runtime = runtimeVersion(paths)
        let prepared: PreparedBundle
        do {
            let bundle = try VMBundle.open(arguments.bundle)
            prepared = try LaunchCoordinator.prepareBundle(
                bundle, paths: paths, runtimeVersion: runtime,
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
        let controller = makeController(prepared, runtimeVersion: runtime, paths: paths)
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
        showWindow = { backend.showDisplay() }
        Task { @MainActor in
            var selfTested = false
            for await state in controller.stateChanges where state == .running {
                if !headless { backend.showDisplay() }
                if !selfTested {
                    selfTested = true
                    Task { await Self.captureSelfTest(backend) }
                }
            }
        }
        Task { @MainActor in
            for await _ in controller.displayRequests { backend.showDisplay() }
        }
    }
}

extension HelperDelegate {
    private static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "display")

    /// C2 capture reads undocumented view internals: once per helper launch, check that a running guest's
    /// frame can be read. A booting guest may show black for a while, so it retries for about a minute;
    /// a failure is logged (fallback: capture through the guest agent, Phase 07).
    @MainActor static func captureSelfTest(_ backend: VZBackend) async {
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(5))
            if backend.captureSelfTest() {
                log.info("capture self-test passed")
                return
            }
        }
        log.notice("capture self-test failed: no readable non-black frame within 60 s")
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

/// The runtime copy this helper runs from (`runtime/<version>/VMPaneVM.app`): the app keeps that directory
/// while the helper lives. A helper started from the app bundle itself (development, integration tests)
/// makes the copy the app would make when the app has QEMU, so QEMU always runs from `runtime/<version>/qemu`;
/// otherwise it reports the app version.
private func runtimeVersion(_ paths: VMPanePaths) -> String {
    let store = RuntimeStore(paths: paths)
    if let version = store.version(ofHelperAt: Bundle.main.bundleURL) { return version }
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let items = RuntimeStore.helperItems(app: app)
    guard items.count > 1 else { return VMPane.version }
    let version = RuntimeStore.version(app: app, appVersion: VMPane.version)
    do {
        try store.ensure(version: version, items: items)
    } catch {
        FileHandle.standardError.write(Data("VMPaneVM: cannot make the runtime copy: \(error)\n".utf8))
        return VMPane.version
    }
    return version
}

extension HelperDelegate {
    /// Chooses the backend (saving first-start config changes) and builds the controller.
    fileprivate func makeController(_ prepared: PreparedBundle, runtimeVersion: String, paths: VMPanePaths) -> HelperController {
        let made: BackendFactory.Made
        do {
            made = try BackendFactory.make(prepared, runtime: paths.runtime(version: runtimeVersion))
        } catch {
            FileHandle.standardError.write(Data("VMPaneVM: cannot prepare the VM: \(error)\n".utf8))
            made = BackendFactory.Made(backend: nil, config: prepared.config)
        }
        let controller = HelperController(
            prepared: prepared, runtimeVersion: runtimeVersion, backend: made.backend, config: made.config,
            afterStart: made.afterStart, afterStop: made.afterStop
        ) {
            DispatchQueue.main.async { exit(0) }
        }
        self.controller = controller
        if let qemu = made.backend as? QEMUBackend {
            observeSpiceDisplay(controller, backend: qemu, config: made.config)
        }
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

extension HelperDelegate {
    /// Windows VMs: the SPICE display, connected while the VM runs (QEMU restarts on resume and restore), its
    /// window shown at start (unless headless) and on `vm.display.show`. Needs the SPICE client libraries
    /// (weak-linked; they come with the QEMU bundle).
    fileprivate func observeSpiceDisplay(_ controller: HelperController, backend: QEMUBackend, config: VMConfigV1) {
        guard SpiceLibraries.available else {
            Self.log.error("SPICE client libraries missing: the VM has no display window")
            return
        }
        let size = CGSize(width: max(config.display.widthPx / 2, 640), height: max(config.display.heightPx / 2, 400))
        let display = SpiceDisplay(socket: backend.displaySocket, title: config.name, size: size)
        showWindow = { display.show() }
        let headless = arguments.headless
        let capture = ProcessInfo.processInfo.environment["VMPANE_TEST_SPICE_CAPTURE"].map { URL(fileURLWithPath: $0) }
        Task { await backend.setBeforeQuit { await display.disconnectAndWait() } }
        Task { @MainActor in
            var shown = false
            for await state in controller.stateChanges {
                switch state {
                case .running, .paused:
                    if state == .running {
                        let current = await controller.currentConfig
                        display.configure(display: current.display.fields, clipboard: current.clipboard.fields.mode)
                    }
                    display.connect(afterStart: state == .running)
                    if !headless, !shown {
                        shown = true
                        display.show()
                    }
                    if let capture { Task { await Self.captureSpice(display, to: capture) } }
                case .stopped, .error:
                    display.disconnect()
                default:
                    break
                }
            }
        }
        Task { @MainActor in
            for await _ in controller.displayRequests { display.show() }
        }
    }

    /// Integration-test hook: rewrites what the SPICE client has, as PNG, every 2 s for 2 minutes after a start.
    @MainActor static func captureSpice(_ display: SpiceDisplay, to output: URL) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            if let png = await display.capturePNG() { try? png.write(to: output, options: .atomic) }
        }
    }
}
