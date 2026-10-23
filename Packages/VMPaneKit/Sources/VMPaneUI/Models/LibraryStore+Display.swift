import Foundation
import VMPaneCore

/// How the library shows a VM: its tile, its system's name and its size.
extension LibraryStore.Row {
    /// The tile: a Linux VM's distribution, guessed from its name (VMPane names a cloud image's VM after it), only
    /// colours it.
    public var system: SystemTile.System {
        let distro = ["ubuntu", "debian", "fedora"].first { name.lowercased().contains($0) }
        return SystemTile.System(os, distro: distro)
    }

    /// "macOS", "Linux", "Windows" (the distribution in `system` is a guess: it never shows as text).
    public var systemName: String { OSBadge.name(os) }

    /// "4 CPUs · 8 GB" ("1 CPU · 512 MB").
    public var spec: String? {
        guard let cpuCount, let memoryMiB else { return nil }
        let memory = memoryMiB >= 1024 ? "\(memoryMiB >> 10) GB" : "\(memoryMiB) MB"
        return "\(cpuCount) \(cpuCount == 1 ? "CPU" : "CPUs") · \(memory)"
    }
}
