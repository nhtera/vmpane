import Foundation
import VMPaneCore

/// Checks a user-supplied or downloaded ISO before a Windows install: mounted read-only (never anything run from
/// it), it must boot arm64 UEFI and hold a Windows 11 ARM64 install image, whose editions are listed.
public enum WindowsISOInspector {
    public enum Verdict: Equatable, Sendable {
        case windows11(editions: [WindowsImage])
        /// No arm64 UEFI loader, or only x64/x86 images.
        case notArm64
        /// An ARM64 Windows before Windows 11 (build < 22000).
        case notWindows11(build: Int?)
        /// Mountable but not Windows install media.
        case notWindows
        case unreadable
    }

    public static func inspect(_ iso: URL) -> Verdict {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("vmpane-iso-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)) != nil else { return .unreadable }
        defer { try? FileManager.default.removeItem(at: mount) }
        guard run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-quiet", "-mountpoint", mount.path, iso.path])
        else {
            return .unreadable
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        return inspect(mounted: mount)
    }

    /// The checks on a mounted (or unpacked) ISO.
    static func inspect(mounted root: URL) -> Verdict {
        let fm = FileManager.default
        func exists(_ candidates: [String]) -> URL? {
            candidates.map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        }
        guard let image = exists(["sources/install.wim", "sources/install.esd", "SOURCES/INSTALL.WIM", "SOURCES/INSTALL.ESD"]) else {
            return exists(["efi/boot/bootaa64.efi", "EFI/BOOT/BOOTAA64.EFI"]) == nil ? .notArm64 : .notWindows
        }
        guard exists(["efi/boot/bootaa64.efi", "EFI/BOOT/BOOTAA64.EFI"]) != nil else { return .notArm64 }
        guard let images = try? WIMHeaderReader.images(of: image), !images.isEmpty else { return .notWindows }
        let arm64 = images.filter(\.isARM64)
        guard !arm64.isEmpty else { return .notArm64 }
        let windows11 = arm64.filter(\.isWindows11)
        guard !windows11.isEmpty else { return .notWindows11(build: arm64.compactMap(\.build).max()) }
        return .windows11(editions: windows11)
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        guard let child = try? ChildSpawner.spawn(URL(fileURLWithPath: tool), .init(arguments: arguments)) else { return false }
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        return status == 0
    }
}
