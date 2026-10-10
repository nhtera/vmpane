import Foundation
import VMPaneCore
import Virtualization

/// Hands the VM to main-actor UI code: only `VZVirtualMachineView.virtualMachine` is set from it.
/// Every other use of the VM stays on its queue (ADR 0003).
public final class VMBox: @unchecked Sendable {
    public let virtualMachine: VZVirtualMachine
    init(_ virtualMachine: VZVirtualMachine) { self.virtualMachine = virtualMachine }
}

/// Owns one `VZVirtualMachine` on its own serial queue (ADR 0003, pattern b): the actor's executor *is*
/// the VM queue, so every VZ call made from its methods is on the right queue, and VZ's async APIs resume
/// there too. Delegate callbacks become `BackendEvent`s.
actor VZRunner {
    let queue = DispatchSerialQueue(label: "app.vmpane.vm")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated let events: AsyncStream<BackendEvent>
    private nonisolated let continuation: AsyncStream<BackendEvent>.Continuation
    private var vm: VZVirtualMachine?
    private var configuration: VZVirtualMachineConfiguration?
    private var delegate: Delegate?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
    }

    /// Builds the configuration and the VM on the VM queue. Returns the box for the display view.
    func create(_ plan: VZPlan, serialLog: FileHandle?) throws -> VMBox {
        dispatchPrecondition(condition: .onQueue(queue))
        let configuration = try VZMaterializer.configuration(plan, serialLog: serialLog)
        try configuration.validate()
        let vm = VZVirtualMachine(configuration: configuration, queue: queue)
        let delegate = Delegate(continuation)
        vm.delegate = delegate
        self.vm = vm
        self.configuration = configuration
        self.delegate = delegate
        return VMBox(vm)
    }

    private func machine() throws -> VZVirtualMachine {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let vm else { throw VZRunnerError.notCreated }
        return vm
    }

    func start() async throws {
        try await machine().start()
        continuation.yield(.started)
    }

    /// Restores saved RAM state into the stopped VM, then runs it.
    func restore(from url: URL) async throws {
        let vm = try machine()
        try await vm.restoreMachineStateFrom(url: url)
        try await vm.resume()
        continuation.yield(.started)
    }

    func pause() async throws {
        try await machine().pause()
        continuation.yield(.paused)
    }

    func resume() async throws {
        try await machine().resume()
        continuation.yield(.resumed)
    }

    /// Asks the guest to shut down (ACPI power button); `.stopped` arrives when it does.
    func requestStop() throws {
        try machine().requestStop()
    }

    /// Powers off at once.
    func forceStop(reason: String) async throws {
        let vm = try machine()
        guard vm.canStop else { return }
        try await vm.stop()
        continuation.yield(.stopped(reason: reason))
    }

    /// Saves RAM state of the paused VM to `url`.
    func save(to url: URL) async throws {
        let vm = try machine()
        try configuration?.validateSaveRestoreSupport()
        try await vm.saveMachineStateTo(url: url)
    }

    /// Before installing macOS: loads the restore image, checks this Mac can run it, and creates the
    /// guest's platform files (hardware model, new machine identifier, auxiliary storage).
    func prepareMacInstall(restoreImage url: URL, aux: VZMacAux) async throws {
        let image = try await VZMacOSRestoreImage.image(from: url)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VZRunnerError.unsupportedRestoreImage
        }
        let model = requirements.hardwareModel
        try FileManager.default.createDirectory(at: aux.hardwareModel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableWrite.write(model.dataRepresentation, to: aux.hardwareModel)
        try DurableWrite.write(VZMacMachineIdentifier().dataRepresentation, to: aux.machineIdentifier)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: aux.auxiliaryStorage, hardwareModel: model, options: [.allowOverwrite])
    }

    /// Installs macOS from `restoreImage` into the (stopped) VM, reporting progress as events.
    func install(restoreImage url: URL) async throws {
        let vm = try machine()
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: url)
        let continuation = continuation
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            continuation.yield(.installProgress(fraction: progress.fractionCompleted, message: "Installing macOS"))
        }
        defer { observation.invalidate() }
        try await installer.install()
        continuation.yield(.installProgress(fraction: 1, message: "macOS installed"))
    }

    // MARK: - Live settings (S11)

    /// Replaces the shares of the VMPane share device; false if the VM was created without one.
    func replaceShares(_ shares: [VZPlan.Share]) -> Bool {
        guard let device = shareDevice() else { return false }
        var directories: [String: VZSharedDirectory] = [:]
        for share in shares { directories[share.name] = VZSharedDirectory(url: share.url, readOnly: share.readOnly) }
        device.share = VZMultipleDirectoryShare(directories: directories)
        return true
    }

    /// Plugs NIC `device` into NAT or unplugs it.
    func setNetworkAttached(device: Int, _ attached: Bool) -> Bool {
        guard let vm, vm.networkDevices.indices.contains(device) else { return false }
        vm.networkDevices[device].attachment = attached ? VZNATNetworkDeviceAttachment() : nil
        return true
    }

    func reconfigureDisplay(widthPx: Int, heightPx: Int) -> Bool {
        guard let display = vm?.graphicsDevices.first?.displays.first else { return false }
        do {
            try display.reconfigure(sizeInPixels: CGSize(width: widthPx, height: heightPx))
            return true
        } catch {
            return false
        }
    }

    private func shareDevice() -> VZVirtioFileSystemDevice? {
        let tags = [VZPlan.sharesTag, VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag]
        return vm?.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDevice }.first { tags.contains($0.tag) }
    }

    /// Tries each runtime change on the running VM and reports `live` or the error (the S11 matrix).
    /// Only for the `--probe-live` measurement; it changes the VM's devices.
    func probeLiveChanges(scratch: URL) async -> [String: String] {
        guard let vm else { return [:] }
        var results: [String: String] = [:]
        func outcome(_ error: Error?) -> String { error.map { "error: \($0.localizedDescription)" } ?? "live" }
        if let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice {
            balloon.targetVirtualMachineMemorySize = (configuration?.memorySize ?? 0) / 2
            results["balloon.target"] = "live"
        } else {
            results["balloon.target"] = "error: no balloon device"
        }
        if let nic = vm.networkDevices.first {
            nic.attachment = nil
            nic.attachment = VZNATNetworkDeviceAttachment()
            results["network.detach+reattach"] = "live"
        } else {
            results["network.detach+reattach"] = "error: no network device"
        }
        if let display = vm.graphicsDevices.first?.displays.first {
            var failure: Error?
            do { try display.reconfigure(sizeInPixels: CGSize(width: 1024, height: 768)) } catch { failure = error }
            results["display.reconfigure"] = outcome(failure)
        } else {
            results["display.reconfigure"] = "error: no display"
        }
        if let share = shareDevice() {
            share.share = VZMultipleDirectoryShare(directories: ["probe": VZSharedDirectory(url: scratch, readOnly: true)])
            results["virtiofs.share.replace"] = "live"
        } else {
            results["virtiofs.share.replace"] = "error: no share device"
        }
        results["usb.massStorage.attach+detach"] = await probeUSBHotPlug(scratch: scratch)
        results["audio.mute"] = "impossible: no API to change sound streams while running"
        results["cpu.count"] = "restart: fixed at VM creation"
        results["memory.size"] = "restart: fixed at VM creation (balloon lowers the target only)"
        return results
    }

    /// USB mass storage hot-plug (macOS 15): attach, then detach, a small image.
    private func probeUSBHotPlug(scratch: URL) async -> String {
        guard let controller = vm?.usbControllers.first else { return "error: no USB controller" }
        let image = scratch.appendingPathComponent("hotplug.img")
        FileManager.default.createFile(atPath: image.path, contents: Data(count: 1 << 20))
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: image, readOnly: true)
            let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            // The completion-handler forms keep `controller` on this actor (the async forms send it).
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                controller.attach(device: device) { error in error.map { done.resume(throwing: $0) } ?? done.resume() }
            }
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                controller.detach(device: device) { error in error.map { done.resume(throwing: $0) } ?? done.resume() }
            }
            return "live"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    var state: VZVirtualMachine.State {
        get throws { try machine().state }
    }

    /// Bridges `VZVirtualMachineDelegate` (called on the VM queue) to backend events.
    private final class Delegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
        private let continuation: AsyncStream<BackendEvent>.Continuation

        init(_ continuation: AsyncStream<BackendEvent>.Continuation) {
            self.continuation = continuation
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            continuation.yield(.stopped(reason: "guest shut down"))
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
            continuation.yield(.failed(message: error.localizedDescription))
        }
    }
}

enum VZRunnerError: Error, Equatable {
    case notCreated
    /// The restore image needs hardware or a host macOS this Mac does not have.
    case unsupportedRestoreImage
}
