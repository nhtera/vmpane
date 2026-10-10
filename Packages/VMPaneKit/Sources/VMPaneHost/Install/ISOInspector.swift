import Foundation
import VMPaneCore

/// Checks that a user-supplied ISO can boot an arm64 VM: mounted read-only, it must contain
/// `EFI/BOOT/BOOTAA64.EFI` (the removable-media boot path for arm64 UEFI).
public enum ISOInspector {
    public enum Verdict: Equatable, Sendable {
        case arm64
        /// No arm64 UEFI loader: likely an x86_64 image.
        case notArm64
        case unreadable
    }

    public static func inspect(_ iso: URL) -> Verdict {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("vmpane-iso-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)) != nil else { return .unreadable }
        defer { try? FileManager.default.removeItem(at: mount) }
        guard run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-quiet", "-mountpoint", mount.path, iso.path]) else {
            return .unreadable
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let candidates = ["EFI/BOOT/BOOTAA64.EFI", "efi/boot/bootaa64.efi"]
        return candidates.contains { FileManager.default.fileExists(atPath: mount.appendingPathComponent($0).path) } ? .arm64 : .notArm64
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        guard let child = try? ChildSpawner.spawn(URL(fileURLWithPath: tool), .init(arguments: arguments)) else { return false }
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        return status == 0
    }
}
