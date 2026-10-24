import AppKit
import VMPaneControl
import VMPaneCore
import VMPaneHost
import VMPaneQEMU
import VMPaneSpice
import VMPaneUI
import VMPaneVZ
import os

/// Per-VM helper app: one process per running VM, with its own Dock tile and window.
/// Usage: VMPaneVM --vm <bundle> [--headless]
@main
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    var controller: HelperController?
    var signalSources: [DispatchSourceSignal] = []
    var crashReports: CrashReports?
    /// Shows the VM's window (set once the display exists). Closing the window only hides it: the VM keeps running.
    var showWindow: (@MainActor () -> Void)?
    /// The VM window's model: this helper's own control socket, as any client sees it.
    @MainActor var windowModel: HelperViewModel?
    /// Window delegates (a window does not retain its delegate).
    @MainActor var windowClosers: [ObjectIdentifier: WindowCloser] = [:]
    /// The guest's screen in each VM window: the person's own keys and clicks there take over from an AI agent.
    @MainActor var displayViews: [NSView] = []
    @MainActor var inputMonitor: Any?
    /// The bundle this helper runs, once prepared.
    var prepared: PreparedBundle?

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

    /// Quit (its menu item, ⌘Q, the Dock tile's menu) ends the VM as the helper's shutdown does: shut down cleanly,
    /// or suspended when closing its window suspends it, then the process exits. Asked first while the VM runs.
    /// (Left to AppKit, the process would end at once and take a running VM with it.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        if let model = windowModel, [.starting, .running, .paused, .stopping].contains(model.state) {
            let alert = NSAlert()
            alert.messageText = "Stop \(model.name ?? "the VM") and quit?"
            alert.informativeText =
                "It is running. Quitting shuts it down first (or suspends it, if closing its window suspends it)."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task { await controller.shutdown() }  // exits once the VM is down (the controller's onShutdown)
        return .terminateLater
    }

    /// The menu bar: the app menu (About, Hide, Quit), Edit (for the settings' text fields), VM (its guest tools) and
    /// Window. Without one the app's menu is empty and ⌘Q does nothing. Keys a captured guest display takes still go
    /// to the guest.
    static func mainMenu() -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "VMPane VM"
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        _ = submenu(
            name,
            [
                item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                .separator(),
                item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
                .separator(),
                item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
            ])
        _ = submenu(
            "Edit",
            [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
            ])
        main.addItem(vmMenu())
        NSApp.windowsMenu = submenu(
            "Window",
            [
                item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                item("Zoom", #selector(NSWindow.performZoom(_:))),
                .separator(),
                item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
            ])
        return main
    }

    /// The VM menu: its guest tools, for the window's model once there is one (the menu is made before it).
    static func vmMenu() -> NSMenuItem {
        func model() -> HelperViewModel? { (NSApp.delegate as? HelperDelegate)?.windowModel }
        let menu = NSMenu(title: "VM")
        menu.addItem(DockMenuItem(title: "Install Guest Tools…") { model()?.showToolsBanner() })
        menu.addItem(DockMenuItem(title: "Update Guest Tools") { if let model = model() { Task { await model.updateGuestTools() } } })
        let holder = NSMenuItem(title: "VM", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// A click on the Dock tile brings a closed window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, !arguments.headless { MainActor.assumeIsolated { showWindow?() } }
        return true
    }

    /// SIGTERM and SIGINT shut the VM down cleanly (or just exit before anything is owned).
    private func handleTerminationSignals() {
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Signals first: a SIGTERM during start-up must not kill the helper half-way through preparing.
        handleTerminationSignals()
        NSApp.mainMenu = Self.mainMenu()
        let paths = VMPanePaths.standard()
        crashReports = .start(paths: paths, process: "helper")
        RunDirectoryReconciler.reconcile(paths: paths)
        let runtime = runtimeVersion(paths)
        var prepared: PreparedBundle
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
        if let request = ProcessInfo.processInfo.environment["VMPANE_TEST_WIN_INSTALL"] {
            prepared = Self.prepareWindowsInstall(prepared, request: URL(fileURLWithPath: request))
        }
        self.prepared = prepared
        let controller = makeController(prepared, runtimeVersion: runtime, paths: paths)
        Task {
            await Self.sharePasteboard(controller)
            await controller.setConfirmationPresenter(
                { [weak self] question in await self?.askInWindow(question) ?? false },
                dismiss: { [weak self] in
                    await MainActor.run {
                        self?.windowModel?.dismissApproval()
                        ConfirmationDialog.dismiss()
                    }
                })
        }
        Task {
            do {
                try await controller.start()
                await self.connectWindowModel(socket: prepared.runFiles.socketURL, bundle: prepared.lock.bundle)
            } catch {
                FileHandle.standardError.write(Data("VMPaneVM: cannot bind the control socket: \(error)\n".utf8))
                await controller.shutdown()
            }
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
    /// The Mac's pasteboard for the VM's clipboard sharing. Integration-test hook (`VMPANE_TEST_PASTEBOARD`): a named
    /// pasteboard of the test's instead, shared as while the window is in front (a headless VM has none); the Mac's
    /// own clipboard is then never shared.
    fileprivate static func sharePasteboard(_ controller: HelperController) async {
        if let name = ProcessInfo.processInfo.environment["VMPANE_TEST_PASTEBOARD"] {
            await controller.setHostPasteboard(GeneralPasteboard(named: name))
            await controller.windowFocusChanged(true)
        } else {
            await controller.setHostPasteboard(GeneralPasteboard())
        }
    }

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
        display.dragOut = SpiceDragOut(
            probe: { await controller.dragOutProbe().map { SpiceDragOut.Item(path: $0.path, folder: $0.folder ?? false) } },
            copy: { try await controller.dragOutCopy($0, to: $1) })
        showWindow = { display.show() }
        Task { await controller.setDisplaySource(display) }
        Task { @MainActor in
            // The model connects right after the control socket is up; the SPICE window exists from launch.
            for _ in 0..<50 where windowModel == nil { try? await Task.sleep(for: .milliseconds(100)) }
            dress(display.window, display: display.displayView) { display.window.orderOut(nil) }
        }
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
                        display.configure(
                            display: current.display.fields, clipboard: current.clipboard.fields.mode, audio: current.audio.fields)
                    }
                    display.connect(afterStart: state == .running)
                    if state == .running, !(await controller.startedHeadless), !shown {
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
