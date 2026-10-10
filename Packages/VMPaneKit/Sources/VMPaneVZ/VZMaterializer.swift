import Foundation
import Virtualization

/// Turns a `VZPlan` into a `VZVirtualMachineConfiguration`. Construction works anywhere; `validate()`
/// needs the virtualization entitlement (a signed binary, e.g. `VMPaneVM --validate-config`).
public enum VZMaterializer {
    public enum Failure: Error, Equatable, Sendable {
        case cannotCreateEFIVariableStore
        case invalidMachineIdentifier
        case invalidHardwareModel
        /// A macOS guest's platform files are missing: install it first.
        case notInstalled
    }

    public static func configuration(_ plan: VZPlan, serialLog: FileHandle?) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        try applyPlatform(plan, to: configuration)
        configuration.cpuCount = max(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(plan.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        configuration.memorySize = plan.memoryBytes
        configuration.storageDevices = try storageDevices(plan)
        // An XHCI controller allows USB mass-storage devices to be attached and detached while running.
        configuration.usbControllers = [VZXHCIControllerConfiguration()]
        configuration.networkDevices = networkDevices(plan)
        applyDisplayAndInput(plan, to: configuration)
        configuration.audioDevices = audioDevices(plan)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if plan.balloon { configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()] }
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.consoleDevices = plan.spiceClipboard ? [spiceConsole()] : []
        if let serialLog {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: serialLog)
            configuration.serialPorts = [serial]
        }
        configuration.directorySharingDevices = directoryShares(plan)
        return configuration
    }

    private static func applyPlatform(_ plan: VZPlan, to configuration: VZVirtualMachineConfiguration) throws {
        switch plan.platform {
        case .generic(let identifierData, let efiURL, let nested):
            let platform = VZGenericPlatformConfiguration()
            guard let identifier = VZGenericMachineIdentifier(dataRepresentation: identifierData) else {
                throw Failure.invalidMachineIdentifier
            }
            platform.machineIdentifier = identifier
            if nested, VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
                platform.isNestedVirtualizationEnabled = true
            }
            configuration.platform = platform
            let boot = VZEFIBootLoader()
            boot.variableStore =
                FileManager.default.fileExists(atPath: efiURL.path)
                ? VZEFIVariableStore(url: efiURL)
                : try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
            configuration.bootLoader = boot
        case .mac(let aux, _):
            guard let modelData = try? Data(contentsOf: aux.hardwareModel), let idData = try? Data(contentsOf: aux.machineIdentifier) else {
                throw Failure.notInstalled
            }
            guard let model = VZMacHardwareModel(dataRepresentation: modelData), model.isSupported else {
                throw Failure.invalidHardwareModel
            }
            guard let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else { throw Failure.invalidMachineIdentifier }
            let platform = VZMacPlatformConfiguration()
            platform.hardwareModel = model
            platform.machineIdentifier = identifier
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: aux.auxiliaryStorage)
            configuration.platform = platform
            configuration.bootLoader = VZMacOSBootLoader()
        }
    }

    private static func storageDevices(_ plan: VZPlan) throws -> [VZStorageDeviceConfiguration] {
        try plan.disks.map { disk in
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: disk.url, readOnly: disk.readOnly, cachingMode: .automatic, synchronizationMode: .fsync)
            switch disk.kind {
            case .virtioBlock: return VZVirtioBlockDeviceConfiguration(attachment: attachment)
            case .usbMassStorage: return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
            }
        }
    }

    private static func networkDevices(_ plan: VZPlan) -> [VZNetworkDeviceConfiguration] {
        plan.networks.map { nic in
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            if let address = VZMACAddress(string: nic.macAddress) { device.macAddress = address }
            return device
        }
    }

    private static func applyDisplayAndInput(_ plan: VZPlan, to configuration: VZVirtualMachineConfiguration) {
        if case .mac = plan.platform {
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    widthInPixels: plan.display.widthPx, heightInPixels: plan.display.heightPx, pixelsPerInch: plan.pixelsPerInch)
            ]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZMacKeyboardConfiguration()]
            configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
            return
        }
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: plan.display.widthPx, heightInPixels: plan.display.heightPx)]
        configuration.graphicsDevices = [gpu]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private static func audioDevices(_ plan: VZPlan) -> [VZAudioDeviceConfiguration] {
        guard plan.audioOutput || plan.audioInput else { return [] }
        let sound = VZVirtioSoundDeviceConfiguration()
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
        if plan.audioOutput {
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            streams.append(output)
        }
        if plan.audioInput {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        sound.streams = streams
        return [sound]
    }

    private static func spiceConsole() -> VZConsoleDeviceConfiguration {
        let console = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = true
        port.attachment = spice
        console.ports[0] = port
        return console
    }

    private static func directoryShares(_ plan: VZPlan) -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        if !plan.shares.isEmpty {
            var isMac = false
            if case .mac = plan.platform { isMac = true }
            // macOS guests mount the automount tag by themselves (under /Volumes/My Shared Files).
            let device = VZVirtioFileSystemDeviceConfiguration(
                tag: isMac ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : VZPlan.sharesTag)
            var directories: [String: VZSharedDirectory] = [:]
            for share in plan.shares { directories[share.name] = VZSharedDirectory(url: share.url, readOnly: share.readOnly) }
            device.share = VZMultipleDirectoryShare(directories: directories)
            devices.append(device)
        }
        if plan.rosetta, VZLinuxRosettaDirectoryShare.availability == .installed, let rosetta = try? VZLinuxRosettaDirectoryShare() {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: VZPlan.rosettaTag)
            device.share = rosetta
            devices.append(device)
        }
        return devices
    }

    /// A new random machine identifier (base64 of its data representation), for `platform.machineIdentifier`.
    public static func newMachineIdentifier() -> String {
        VZGenericMachineIdentifier().dataRepresentation.base64EncodedString()
    }
}
