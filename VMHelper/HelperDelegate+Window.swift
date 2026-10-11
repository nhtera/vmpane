import AppKit
import VMPaneControl
import VMPaneCore
import VMPaneHost
import VMPaneQEMU
import VMPaneSpice
import VMPaneUI
import VMPaneVZ
import os

extension HelperDelegate {
    /// Integration-test hook (win-install): the wizard's step, done before any start under this helper's lock, with
    /// the same `WindowsInstall.prepare` and `ConfigStore.save`. The request (0600 JSON, read once and deleted, as
    /// it holds the password): `{iso, tools?, locale, timeZone, computerName, userName, password, editionName}`.
    static func prepareWindowsInstall(_ prepared: PreparedBundle, request: URL) -> PreparedBundle {
        struct Request: Decodable {
            var iso: String
            var tools: String?
            var locale: String
            var timeZone: String
            var computerName: String
            var userName: String
            var password: String
            var editionName: String
        }
        do {
            // Only a private file of this user's, never through a link: the hook deletes what it read.
            guard PrivateFile.isPrivateRegularFile(request) else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: request)
            try? FileManager.default.removeItem(at: request)
            let wanted = try JSONDecoder().decode(Request.self, from: data)
            let input = UnattendInput(
                locale: wanted.locale, timeZone: wanted.timeZone, computerName: wanted.computerName, userName: wanted.userName,
                password: wanted.password, editionName: wanted.editionName, eulaAcceptedAt: Date())
            let config = try WindowsInstall.prepare(
                prepared.config, iso: URL(fileURLWithPath: wanted.iso), input: input,
                tools: wanted.tools.map { URL(fileURLWithPath: $0) }, holding: prepared.lock)
            try ConfigStore.save(config, holding: prepared.lock)
            return prepared.replacing(config: config)
        } catch {
            FileHandle.standardError.write(Data("VMPaneVM: cannot prepare the Windows install: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor func connectWindowModel(socket: URL, bundle: VMBundle) async {
        guard let client = try? UDSClient.connect(to: socket) else { return }
        let model = HelperViewModel(channel: client)
        windowModel = model
        await model.start()
        let os = (try? ConfigStore.load(bundle))?.os
        let custom = NSImage(contentsOf: bundle.url.appendingPathComponent("icon.png"))
        followDockTile(model, os: os, custom: custom)
    }

    /// The Dock tile shows the VM's icon and state, and changes with it.
    @MainActor func followDockTile(_ model: HelperViewModel, os: GuestOS?, custom: NSImage?) {
        let state = withObservationTracking {
            model.state
        } onChange: {
            Task { @MainActor [weak self] in self?.followDockTile(model, os: os, custom: custom) }
        }
        NSApp.applicationIconImage = DockIcon.image(os: os, state: state, custom: custom)
        NSApp.dockTile.badgeLabel = DockIcon.badge(state)
    }

    /// The Dock menu: the window, power, pause and a snapshot, for this VM.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = windowModel else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false  // the items say themselves whether they apply
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = DockMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Show Window") { [weak self] in self?.showWindow?() }
        menu.addItem(.separator())
        if model.can(.start) {
            add("Start") { Task { await model.perform(.start) } }
        } else {
            add("Shut Down", enabled: model.can(.shutDown)) { Task { await model.perform(.shutDown) } }
        }
        if model.can(.resume) {
            add("Resume") { Task { await model.perform(.resume) } }
        } else {
            add("Pause", enabled: model.can(.pause)) { Task { await model.perform(.pause) } }
        }
        add("Take Snapshot", enabled: model.can(.snapshot)) { Task { await model.perform(.snapshot) } }
        return menu
    }

    /// Wraps a display window in the VM window's content (toolbar, overlays) once the model is there, keeps its
    /// frame across starts, and makes closing it follow the VM's close action instead of destroying it.
    @MainActor func dress(
        _ window: NSWindow, display: NSView, captureKeys: (@MainActor (Bool) -> Void)? = nil,
        hide: @escaping @MainActor () -> Void
    ) {
        guard let windowModel, let controller else { return }
        VMWindowContent.install(in: window, display: display, model: windowModel, captureKeys: captureKeys)
        let vmID = prepared?.config.id.uuidString ?? "vm"
        window.setFrameAutosaveName("VMPane.vm.\(vmID)")
        let closer = WindowCloser(model: windowModel, controller: controller, hide: hide)
        windowClosers[ObjectIdentifier(window)] = closer
        window.delegate = closer
    }

    /// Shows the VM's window when it starts (unless headless) or when `vm.display.show` asks for it.
    func observeDisplay(_ controller: HelperController, backend: VZBackend, config: VMConfigV1) {
        Task { @MainActor in
            backend.onDisplayCreated = { [weak self] window, view in
                self?.dress(
                    window, display: view, captureKeys: { backend.captureSystemKeys($0) }, hide: { backend.hideDisplay() })
            }
        }
        showWindow = { backend.showDisplay() }
        Task { @MainActor in
            var selfTested = false
            for await state in controller.stateChanges where state == .running {
                // Each start says whether it wants a window (the library's "Start Without Window").
                if !(await controller.startedHeadless) { backend.showDisplay() }
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
