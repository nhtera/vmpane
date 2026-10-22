import Foundation

/// What an installer file dropped on VMPane (or chosen) is, read from its contents with the installs' own
/// inspectors: a macOS restore image, a Linux ISO or a Windows 11 ISO, or why VMPane cannot use it. Nothing is
/// copied: an ISO is mounted read-only for a moment.
public enum InstallMediaKind: Equatable, Sendable {
    case macRestoreImage
    case linuxISO
    case windowsISO

    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case x64Windows
        case olderWindows(build: Int?)
        case x64Linux
        case unreadable
        case notAnInstaller

        public var description: String {
            switch self {
            case .x64Windows: "This is an x64 ISO. VMPane needs Windows 11 for Arm (ARM64)."
            case .olderWindows(let build):
                "This is an older Windows\(build.map { " (build \($0))" } ?? ""). VMPane needs Windows 11 for Arm (ARM64)."
            case .x64Linux: "This is an x64 ISO. VMPane needs the arm64 (aarch64) edition of the system."
            case .unreadable: "This file cannot be read as an installer: it may be damaged, or not an ISO."
            case .notAnInstaller: "VMPane makes VMs from macOS restore images (.ipsw) and installer ISOs (.iso)."
            }
        }
    }

    /// The kind of `url` (slow for an ISO: call it off the main thread).
    public static func detect(_ url: URL) throws -> InstallMediaKind {
        switch url.pathExtension.lowercased() {
        case "ipsw": return .macRestoreImage
        case "iso": return try kind(windows: WindowsISOInspector.inspect(url)) { ISOInspector.inspect(url) }
        default: throw Refusal.notAnInstaller
        }
    }

    /// An ISO's kind from the Windows inspector's verdict, else (no Windows install image in it) the Linux one's.
    static func kind(windows: WindowsISOInspector.Verdict, linux: () -> ISOInspector.Verdict) throws -> InstallMediaKind {
        switch windows {
        case .windows11: return .windowsISO
        case .notArm64: throw Refusal.x64Windows
        case .notWindows11(let build): throw Refusal.olderWindows(build: build)
        case .notWindows, .unreadable:
            switch linux() {
            case .arm64: return .linuxISO
            case .notArm64: throw Refusal.x64Linux
            case .unreadable: throw Refusal.unreadable
            }
        }
    }
}
