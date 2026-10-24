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
        // A start comes from the VM window (its toolbar or overlay): the alert is a sheet on it.
        model.lowMemoryGuard = .alert { NSApp.keyWindow ?? NSApp.mainWindow }
        windowModel = model
        await model.start()
        let os = (try? ConfigStore.load(bundle))?.os
        let custom = NSImage(contentsOf: bundle.url.appendingPathComponent("icon.png"))
        followDockTile(model, os: os, custom: custom)
    }

    /// An agent's request for the person's yes: in the VM's window (shown first, so the question is seen), else in an
    /// alert: before the VM's first start (no window yet), or while another sheet (Settings, Snapshots) is open on it.
    @MainActor func askInWindow(_ question: ConfirmationRequest) async -> Bool {
        guard let model = windowModel, let showWindow, let window = displayViews.last?.window else {
            return ConfirmationDialog.ask(question)
        }
        showWindow()
        guard window.isVisible, window.attachedSheet == nil || model.approval != nil else { return ConfirmationDialog.ask(question) }
        NSApp.activate()
        return await model.presentApproval(question)
    }

    /// The person's keyboard and mouse in a VM window's screen: real input only (agents' input goes straight to the
    /// display view or QEMU, never through the app's event loop, which this watches).
    @MainActor func watchPersonInput() {
        guard inputMonitor == nil else { return }
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            if let self, self.isOnScreen(event) { self.windowModel?.personActed() }
            return event
        }
    }

    /// Whether `event` is aimed at a guest's screen: a click on it (not the toolbar or the HUD), or a key in its window
    /// that no text field takes (the guest's view need not be the first responder to get keys), but not a ⌘ shortcut
    /// (the window's own). A sheet is a window of its own.
    @MainActor private func isOnScreen(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, displayViews.contains(where: { $0.window === window }) else {
            return false  // a click that only brings the window forward is not one in the guest yet
        }
        if event.type == .keyDown { return !event.modifierFlags.contains(.command) && !(window.firstResponder is NSText) }
        guard let target = window.contentView?.hitTest(event.locationInWindow) else { return false }
        return displayViews.contains { target === $0 || target.isDescendant(of: $0) }
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
        menu.addItem(.separator())
        add(model.agentConnected ? "Update Guest Tools" : "Install Guest Tools…", enabled: model.state == .running) {
            if model.agentConnected { Task { await model.updateGuestTools() } } else { model.showToolsBanner() }
        }
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
        displayViews.removeAll { $0.window == nil || $0.window === window }  // a VZ start's window replaces the last one's
        displayViews.append(display)
        watchPersonInput()
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
