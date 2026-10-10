import AppKit
@preconcurrency import CocoaSpice
@preconcurrency import CocoaSpiceRenderer
import MetalKit
import os

/// The window of a Windows VM: a SPICE client on QEMU's `spice.sock` rendering the guest display with Metal,
/// sending keyboard and mouse input. QEMU is restarted by resume and snapshot restores, so the session
/// reconnects whenever the helper says the VM is running.
/// Only create one when `SpiceLibraries.available`.
@MainActor
public final class SpiceDisplay: NSObject {
    private static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "spice")

    public let window: NSWindow
    private let view: SpiceView
    private let renderer: CSMetalRenderer
    private let socket: URL
    private var connection: CSConnection?
    private var display: CSDisplay?
    /// Whether the session should be connected (the VM runs); a dropped connection is retried meanwhile.
    private var wanted = false
    private static var started = false

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
        view.onResize = { [weak self] in self?.layoutDisplay() }
    }

    /// Shows the window and focuses the guest.
    public func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
    }

    /// Connects (or reconnects) to QEMU's SPICE server.
    public func connect() {
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
        guard connection != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closed.append(continuation)
            teardown(waiting: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishClosing() }
        }
    }

    private var closing: CSConnection?
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

    fileprivate func connected(_ display: CSDisplay) {
        guard display.isPrimaryDisplay else { return }
        self.display = display
        display.addRenderer(renderer)
        layoutDisplay()
        Self.log.info("SPICE display \(Int(display.displaySize.width))x\(Int(display.displaySize.height))")
    }

    fileprivate func updated(_ display: CSDisplay) {
        guard display === self.display else { return }
        layoutDisplay()
    }

    fileprivate func inputAvailable(_ input: CSInput) { view.input = input }

    fileprivate func lost(_ reason: String) {
        Self.log.notice("SPICE session ended: \(reason, privacy: .public)")
        if closing != nil {
            finishClosing()
            return
        }
        retryLater()
    }
}

// CocoaSpice calls its delegate on the SPICE main loop thread; everything moves to the main actor.
extension SpiceDisplay: CSConnectionDelegate {
    nonisolated public func spiceConnected(_ connection: CSConnection) {}

    nonisolated public func spiceDisconnected(_ connection: CSConnection) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.lost("disconnected") } }
    }

    nonisolated public func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        let reason = "error \(code.rawValue): \(message ?? "")"
        DispatchQueue.main.async { MainActor.assumeIsolated { self.lost(reason) } }
    }

    nonisolated public func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        nonisolated(unsafe) let input = input
        DispatchQueue.main.async { MainActor.assumeIsolated { self.inputAvailable(input) } }
    }

    nonisolated public func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {}

    nonisolated public func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        nonisolated(unsafe) let display = display
        DispatchQueue.main.async { MainActor.assumeIsolated { self.connected(display) } }
    }

    nonisolated public func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        nonisolated(unsafe) let display = display
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updated(display) } }
    }

    nonisolated public func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {}
    nonisolated public func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {}
    nonisolated public func spiceAgentDisconnected(_ connection: CSConnection) {}
    nonisolated public func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    nonisolated public func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}
