import Foundation
import Virtualization

/// What this Mac offers VZ guests, for the settings UI: options the Mac cannot provide are hidden
/// (nested virtualization) or offered with an install step (Rosetta). The VM configuration drops an
/// option the Mac lacks instead of failing to start.
public enum VZHostSupport {
    public enum Rosetta: Sendable, Equatable {
        case installed
        /// Supported, but Rosetta is not installed yet (`installRosetta()` asks macOS to install it).
        case notInstalled
        case unsupported
    }

    /// Nested virtualization for Linux guests (`/dev/kvm` in the guest): Apple M3 or later.
    public static var nestedVirtualization: Bool { VZGenericPlatformConfiguration.isNestedVirtualizationSupported }

    public static var rosetta: Rosetta {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed: .installed
        case .notInstalled: .notInstalled
        default: .unsupported
        }
    }

    /// Asks macOS to install Rosetta (the user sees the system's license prompt).
    public static func installRosetta() async throws {
        try await VZLinuxRosettaDirectoryShare.installRosetta()
    }
}
