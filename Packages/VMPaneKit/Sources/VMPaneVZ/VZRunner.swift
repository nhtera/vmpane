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
