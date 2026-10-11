import AppKit
import Foundation
import VMPaneCore
import Virtualization
import os

/// `VMBackend` on Virtualization.framework (Linux guests now; macOS guests follow).
public final class VZBackend: VMBackend {
    public let kind = BackendKind.vz
    public let capabilities: LiveCapabilities = [.pause, .suspend, .liveSnapshot, .screenshot, .input]
    public nonisolated let events: AsyncStream<BackendEvent>
    public nonisolated var agentSockets: AsyncStream<Int32> { runner.agentSockets }

    /// Saved RAM state inside the state directory (see `SavedStateRule`).
    public static let stateFileName = "suspend.vzvmsave"

    /// What a macOS install writes to the VM's disk: macOS 15 takes about 15 GiB, more after its first boot.
    public static let macInstallBytes: UInt64 = 20 << 30

    /// The plan for the next start, and the one the current VM was created from.
    private let plans: OSAllocatedUnfairLock<(next: VZPlan, running: VZPlan?)>
    private let replan: (@Sendable (VMConfigV1) throws -> VZPlan)?
    private let title: String
    private let runner = VZRunner()
    @MainActor private var display: VZDisplayHost?
    /// Called with each new display window and its VM view (a new VM object, and so a new window, per start),
    /// e.g. to put the helper's window content around the view.
    @MainActor public var onDisplayCreated: ((NSWindow, NSView) -> Void)?
    private let serialLog: FileHandle?
    private let box = BoxHolder()

    /// `replan` rebuilds the plan from a saved config at each start (see `StartOptions.config`).
    public init(plan: VZPlan, title: String = "VMPane VM", replan: (@Sendable (VMConfigV1) throws -> VZPlan)? = nil) {
        plans = OSAllocatedUnfairLock(initialState: (plan, nil))
        self.replan = replan
        self.title = title
        events = runner.events
        serialLog = Self.openLog(plan.serialLog)
    }

    /// The VM for the display view, once started.
    public var virtualMachineBox: VMBox? { box.value }

    public func start(_ options: StartOptions) async throws {
        if let config = options.config, let replan {
            let plan = try replan(config)
            plans.withLock { $0.next = plan }
        }
        let plan = plans.withLock { $0.next }
        if case .mac(let aux, let image?) = plan.platform {
            // First start of a macOS guest: install, then boot the installed system. Space is checked before
            // anything is written (once the platform files exist, a start no longer installs).
            try SpaceGuard.require(Self.macInstallBytes, at: aux.auxiliaryStorage)
            try await runner.prepareMacInstall(restoreImage: image, aux: aux)
            try await create(plan)
            try await runner.install(restoreImage: image)
            // The installer leaves the VM running the installed system; start it only if it did not.
            if try await runner.state != .running { try await runner.start() }
            return
        }
        try await create(plan)
        if let directory = options.stateDirectory {
            do {
                try await runner.restore(from: directory.appendingPathComponent(Self.stateFileName))
            } catch  where Self.isLockedRestore(error) {
                throw SavedStateLocked()
            }
        } else {
            try await runner.start()
        }
    }

    public func pause() async throws { try await runner.pause() }
    public func resume() async throws { try await runner.resume() }

    /// Pause, save to `suspend.vzvmsave.partial`, rename, power off. On any failure the VM is resumed.
    public func suspend(to stateDirectory: URL) async throws {
        let final = stateDirectory.appendingPathComponent(Self.stateFileName)
        let partial = stateDirectory.appendingPathComponent(Self.stateFileName + ".partial")
        if try await runner.state == .running { try await runner.pause() }
        do {
            try await runner.save(to: partial)
            try FileManager.default.moveItem(at: partial, to: final)
            try DurableWrite.syncDirectory(stateDirectory)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            try? await runner.resume()
            throw error
        }
        try await runner.forceStop(reason: "suspended")
    }

    public func saveState(to stateDirectory: URL) async throws {
        try await runner.save(to: stateDirectory.appendingPathComponent(Self.stateFileName))
    }

    public func stop(_ mode: StopMode) async throws {
        switch mode {
        case .graceful: try await runner.requestStop()
        case .force: try await runner.forceStop(reason: "forced off")
        }
    }

    /// Creates the VM and its (hidden) display, which capture and input need even headless.
    private func create(_ plan: VZPlan) async throws {
        await MainActor.run {
            display?.close()
            display = nil
        }
        let box = try await runner.create(plan, serialLog: serialLog)
        self.box.value = box
        plans.withLock { $0.running = plan }
        let size = NSSize(width: plan.display.widthPx, height: plan.display.heightPx)
        let title = title
        await MainActor.run {
            let host = VZDisplayHost(box: box, title: title, guestSize: size)
            display = host
            onDisplayCreated?(host.window, host.view)
        }
    }

    /// Live settings per the S11 matrix (`docs/live-capabilities.md`): shares, NIC attach/detach, display size.
    public func applyLive(_ config: VMConfigV1, paths: [String]) async -> Set<String> {
        guard let running = plans.withLock({ $0.running }) else { return [] }
        var applied: Set<String> = []
        for path in paths {
            let parts = path.split(separator: ".").map(String.init)
            switch parts.first {
            case "shares":
                let shares = config.shares.map {
                    VZPlan.Share(name: $0.name, url: URL(fileURLWithPath: $0.hostPath), readOnly: $0.readOnly)
                }
                if await runner.replaceShares(shares) { applied.insert(path) }
            case "display" where parts.last == "autoResize":
                let value = config.display.autoResize
                if await MainActor.run(body: { display?.setAutoResize(value) ?? false }) { applied.insert(path) }
            case "display":
                if await runner.reconfigureDisplay(widthPx: config.display.widthPx, heightPx: config.display.heightPx) {
                    applied.insert(path)
                }
            case "network":
                // Only NICs the VM was created with can be (un)plugged; their order is the plan's.
                guard parts.count == 3, let index = Int(parts[1]), config.network.indices.contains(index) else { continue }
                let nic = config.network[index]
                guard nic.mode != .bridged,
                    let device = running.networks.firstIndex(where: { $0.macAddress == nic.macAddress.lowercased() })
                else { continue }
                if await runner.setNetworkAttached(device: device, nic.mode == .nat) { applied.insert(path) }
            default:
                continue
            }
        }
        return applied
    }

    /// The S11 live-change matrix measured on this running VM (see `VZRunner.probeLiveChanges`).
    public func probeLiveChanges(scratch: URL) async -> [String: String] {
        await runner.probeLiveChanges(scratch: scratch)
    }

    /// The C2 capture self-test (`VZDisplayHost.selfTest`): false when there is no display or the frame is black.
    @MainActor public func captureSelfTest() -> Bool {
        display?.selfTest() ?? false
    }

    /// Makes the VM's window visible.
    @MainActor public func showDisplay() {
        display?.show()
    }

    /// Whether ⌘-shortcuts, ⌘-Tab and the like go to the guest (on) or stay with the Mac (off, the default).
    @MainActor public func captureSystemKeys(_ captured: Bool) {
        display?.view.capturesSystemKeys = captured
    }

    /// Takes the window off screen as the user sees it (it keeps rendering for capture and input).
    @MainActor public func hideDisplay() {
        display?.hide()
    }

    public func screenshot(maxEdge: Int) async throws -> Screenshot {
        let capture = await MainActor.run { display?.capture(maxEdge: maxEdge) }
        guard let capture else { throw VZBackendError.captureUnavailable }
        return Screenshot(png: capture.png, width: capture.width, height: capture.height, scale: capture.scale)
    }

    public func send(_ input: InputEvent) async throws {
        try await MainActor.run {
            guard let display else { throw VZBackendError.captureUnavailable }
            try display.send(input)
        }
    }

    /// Fills in what a VZ guest needs before its first start (a persisted machine identifier).
    /// Returns nil when nothing changed.
    /// After a macOS install: the config records the new machine identifier and drops the install source.
    public static func installed(_ config: VMConfigV1, bundle: VMBundle) -> VMConfigV1? {
        guard config.os == .macos, config.install != nil,
            let identifier = try? Data(contentsOf: VZMacAux(directory: bundle.auxDirectory).machineIdentifier)
        else { return nil }
        var config = config
        config.platform.machineIdentifier = identifier.base64EncodedString()
        config.install = nil
        return config
    }

    public static func prepare(_ config: VMConfigV1) -> VMConfigV1? {
        guard config.os == .linux, config.platform.machineIdentifier == nil else { return nil }
        var config = config
        config.platform.machineIdentifier = VZMaterializer.newMachineIdentifier()
        return config
    }

    /// Saved state is encrypted with a Secure Enclave key that works only while the Mac is unlocked: the
    /// restore then fails with VZErrorDomain 12 "permission denied" (underlying: errSecInteractionNotAllowed).
    static func isLockedRestore(_ error: Error) -> Bool {
        var pending: [NSError] = [error as NSError]
        while let next = pending.popLast() {
            if next.domain == NSOSStatusErrorDomain && next.code == Int(errSecInteractionNotAllowed) { return true }
            if next.domain == VZErrorDomain && next.code == 12,
                (next.localizedFailureReason ?? next.localizedDescription).localizedCaseInsensitiveContains("permission denied")
            {
                return true
            }
            pending += next.underlyingErrors.map { $0 as NSError }
        }
        return false
    }

    private static func openLog(_ url: URL) -> FileHandle? {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    private final class BoxHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var box: VMBox?
        var value: VMBox? {
            get { lock.withLock { box } }
            set { lock.withLock { box = newValue } }
        }
    }
}

public enum VZBackendError: Error, Equatable, Sendable {
    case notAvailableYet(String)
    /// The VM has no display yet, or the view's framebuffer could not be read (fallback: guest agent).
    case captureUnavailable
}

extension VZBackend {
    /// `VZVirtualMachineConfiguration.validate()` for this plan. Needs the virtualization entitlement.
    public static func validate(_ plan: VZPlan) throws {
        try VZMaterializer.configuration(plan, serialLog: nil).validate()
    }
}
