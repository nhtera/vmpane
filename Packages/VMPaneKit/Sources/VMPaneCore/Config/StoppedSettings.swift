import Foundation

/// The hardware the app's inspector changes on a stopped VM (`LibraryOps.updateStopped`).
public struct StoppedSettings: Equatable, Sendable {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case diskShrink, tooSmall

        public var description: String {
            switch self {
            case .diskShrink: "a disk can grow, not shrink"
            case .tooSmall: "a VM needs at least 1 processor and 1 GB of memory"
            }
        }
    }

    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskGiB: Int
    public var displayWidth: Int
    public var displayHeight: Int

    public init(_ config: VMConfigV1) {
        cpuCount = config.cpu.count
        memoryMiB = config.memory.mib
        diskGiB = config.disks.first?.sizeGiB ?? 0
        displayWidth = config.display.widthPx
        displayHeight = config.display.heightPx
    }

    func apply(to config: inout VMConfigV1) {
        config.cpu.count = cpuCount
        config.memory.mib = memoryMiB
        if !config.disks.isEmpty { config.disks[0].sizeGiB = diskGiB }
        config.display.widthPx = displayWidth
        config.display.heightPx = displayHeight
    }
}
