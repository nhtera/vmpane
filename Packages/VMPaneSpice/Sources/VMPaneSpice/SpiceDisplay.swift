import AppKit
@preconcurrency import CocoaSpice
@preconcurrency import CocoaSpiceRenderer
import MetalKit
import VMPaneCore
import VMPaneQEMU
import os

/// The window of a Windows VM: a SPICE client on QEMU's `spice.sock` rendering the guest display with Metal,
/// sending keyboard and mouse input. QEMU is restarted by resume and snapshot restores, so the session
/// reconnects whenever the helper says the VM is running. With spice-vdagent in the guest, the guest resolution
/// follows the window (`display.autoResize`) and text is shared through the clipboard (`clipboard.mode`, only while
/// the window is key).
/// Only create one when `SpiceLibraries.available`.
@MainActor
public final class SpiceDisplay: NSObject {
    private static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "spice")

    public let window: NSWindow
    private let view: SpiceView
    /// The view that shows the guest (to embed the window's own content around it).
    public var displayView: NSView { view }
    private let renderer: CSMetalRenderer
    private let socket: URL
    private var connection: CSConnection?
    private var display: CSDisplay?
    /// Whether the session should be connected (the VM runs); a dropped connection is retried meanwhile.
    private var wanted = false
    private static var started = false
    /// The guest agent's features while it is connected.
    private var agent: CSConnectionAgentFeature?
    private var settings: (display: DisplayConfig, clipboard: ClipboardConfig.Mode)?
    private let pasteboard = SpicePasteboard()
    private var resizeTask: Task<Void, Never>?
    private var clipboardTimer: Timer?

    public init(socket: URL, title: String, size: CGSize) {
        self.socket = socket
        view = SpiceView(frame: NSRect(origin: .zero, size: size), device: MTLCreateSystemDefaultDevice())
        renderer = CSMetalRenderer(metalKitView: view)
        view.delegate = renderer
        window = NSWindow(
            contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.isReleasedWhenClosed = false
        super.init()
        view.onResize = { [weak self] in
            self?.layoutDisplay()
            self?.resizeGuestSoon()
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(focusChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusChanged), name: NSWindow.didResignKeyNotification, object: window)
    }

    /// The VM's display and clipboard settings (read at each start: neither changes while QEMU runs).
    public func configure(display: DisplayConfig, clipboard: ClipboardConfig.Mode) {
        settings = (display, clipboard)
        focusChanged()
    }

    @objc private func focusChanged() {
        let focused = window.isKeyWindow
        pasteboard.update(mode: settings?.clipboard ?? .off, focused: focused)
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        guard focused, settings?.clipboard.sendsToGuest == true else { return }
        pasteboard.offerIfChanged()
        // NSPasteboard has no change notification: poll while the guest has focus.
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pasteboard.offerIfChanged() }
        }
    }

    /// Asks the guest agent for the window's resolution once the window has kept its size for a moment.
    private func resizeGuestSoon() {
        resizeTask?.cancel()
        guard let settings, settings.display.autoResize, agent?.contains(.monitorsConfig) == true else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: SpiceGuestDisplay.resizeDebounce)
            guard !Task.isCancelled, let self, let display = self.display else { return }
            let size = SpiceGuestDisplay.resolution(
                forContent: self.view.bounds.size, backingScale: self.window.backingScaleFactor, scaling: settings.display.scaling)
            guard size != display.displaySize else { return }
            display.requestResolution(CGRect(origin: .zero, size: size))
        }
    }

    /// Shows the window and focuses the guest.
    public func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
    }

    /// Connects (or reconnects) to QEMU's SPICE server. After `disconnectAndWait` (QEMU is quitting) only a
    /// connect for a new QEMU (`afterStart`) reconnects: a late "paused" from the dying QEMU must not.
    public func connect(afterStart: Bool = false) {
        if afterStart { quitting = false }
        guard !quitting else { return }
        wanted = true
        guard connection == nil else { return }
        if !Self.started {
            guard CSMain.shared.spiceStart() else {
                Self.log.error("cannot start the SPICE main loop")
                return
            }
            Self.started = true
        }
        let connection = CSConnection(unixSocketFile: socket)
        connection.delegate = self
        connection.session.pasteboardDelegate = pasteboard
        self.connection = connection
        if !connection.connect() { retryLater() }
    }

    /// The VM stopped: drop the session and keep the window (it shows the last frame).
    public func disconnect() {
        wanted = false
        teardown()
    }

    /// Disconnects and waits (up to 2 s) until the session is closed: QEMU's spice-server can hang in its
    /// cleanup when it exits with a client still connected, so QEMU is quit only after this.
    public func disconnectAndWait() async {
        wanted = false
        quitting = true
        guard connection != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closed.append(continuation)
            teardown(waiting: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishClosing() }
        }
    }

    private var closing: CSConnection?
    private var quitting = false
    private var closed: [CheckedContinuation<Void, Never>] = []

    private func finishClosing() {
        closing?.delegate = nil
        closing = nil
        let waiting = closed
        closed.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// Drops the session; with `waiting`, the connection stays the delegate's until it reports the disconnect.
    private func teardown(waiting: Bool = false) {
        view.input = nil
        agent = nil
        resizeTask?.cancel()
        if let display { display.removeRenderer(renderer) }
        display = nil
        if waiting {
            closing = connection
        } else {
            connection?.delegate = nil
        }
        connection?.disconnect()
        connection = nil
    }

    private func retryLater() {
        teardown()
        guard wanted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.wanted, self.connection == nil else { return }
            self.connect()
        }
    }

    /// Fits the guest display into the view (scaled, centred) and tells the view how to map the mouse.
    private func layoutDisplay() {
        guard let display, display.displaySize.width > 0, display.displaySize.height > 0 else { return }
        let drawable = view.drawableSize
        let scale = min(drawable.width / display.displaySize.width, drawable.height / display.displaySize.height)
        renderer.viewportScale = scale
        renderer.viewportOrigin = .zero
        view.guestSize = display.displaySize
        view.guestScale = scale / max(view.window?.backingScaleFactor ?? 1, 1)
    }

    /// The display as the SPICE client has it, as PNG (integration tests: proves the session renders).
    public func capturePNG() async -> Data? {
        guard let display else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            display.screenshot { shot in continuation.resume(returning: shot?.image) }
        }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The display reduced for input verification, from the frame the SPICE client has in memory (QMP `screendump`
    /// writes a full-size file per frame). Reduced in the client's callback, while its frame is still valid.
    public func grayFrame() async -> GrayFrame? {
        guard let display else { return nil }
        return await withCheckedContinuation { continuation in
            display.screenshot { shot in
                let image = shot?.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                continuation.resume(returning: image.flatMap { GrayFrame($0) })
            }
        }
    }

    fileprivate func connected(_ display: CSDisplay, on source: CSConnection) {
        guard source === connection, display.isPrimaryDisplay else { return }
        self.display = display
        display.addRenderer(renderer)
        layoutDisplay()
        resizeGuestSoon()
        Self.log.info("SPICE display \(Int(display.displaySize.width))x\(Int(display.displaySize.height))")
    }

    fileprivate func updated(_ display: CSDisplay, on source: CSConnection) {
        guard source === connection, display === self.display else { return }
        layoutDisplay()
    }

    fileprivate func inputAvailable(_ input: CSInput, on source: CSConnection) {
        guard source === connection else { return }
        view.input = input
    }

    fileprivate func agentChanged(_ features: CSConnectionAgentFeature?, on source: CSConnection) {
        guard source === connection else { return }
        agent = features
        Self.log.info("SPICE guest agent \(features == nil ? "disconnected" : "connected", privacy: .public)")
        resizeGuestSoon()
    }

    /// Callbacks name their connection: an old session's late callbacks must not touch the current one.
    fileprivate func lost(_ reason: String, on source: CSConnection) {
        if source === closing {
            finishClosing()
        } else if source === connection {
            Self.log.notice("SPICE session ended: \(reason, privacy: .public)")
            retryLater()
        }
    }
}

// CocoaSpice calls its delegate on the SPICE main loop thread; everything moves to the main actor, together
// with the connection that called (CocoaSpice objects are not Sendable; they are only used on the main actor).
extension SpiceDisplay: CSConnectionDelegate {
    nonisolated public func spiceConnected(_ connection: CSConnection) {}

    nonisolated public func spiceDisconnected(_ connection: CSConnection) {
        nonisolated(unsafe) let source = connection
        DispatchQueue.main.async { MainActor.assumeIsolated { self.lost("disconnected", on: source) } }
    }

    nonisolated public func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        let reason = "error \(code.rawValue): \(message ?? "")"
        nonisolated(unsafe) let source = connection
        DispatchQueue.main.async { MainActor.assumeIsolated { self.lost(reason, on: source) } }
    }

    nonisolated public func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        nonisolated(unsafe) let (source, input) = (connection, input)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.inputAvailable(input, on: source) } }
    }

    nonisolated public func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {}

    nonisolated public func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        nonisolated(unsafe) let (source, display) = (connection, display)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.connected(display, on: source) } }
    }

    nonisolated public func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        nonisolated(unsafe) let (source, display) = (connection, display)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updated(display, on: source) } }
    }

    nonisolated public func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {}
    nonisolated public func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        nonisolated(unsafe) let source = connection
        DispatchQueue.main.async { MainActor.assumeIsolated { self.agentChanged(features, on: source) } }
    }

    nonisolated public func spiceAgentDisconnected(_ connection: CSConnection) {
        nonisolated(unsafe) let source = connection
        DispatchQueue.main.async { MainActor.assumeIsolated { self.agentChanged(nil, on: source) } }
    }
    nonisolated public func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    nonisolated public func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}
