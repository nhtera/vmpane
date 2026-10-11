import SwiftUI
import VMPaneCore

/// The guest OS as a symbol and a name.
public struct OSBadge: View {
    let os: GuestOS?

    public init(_ os: GuestOS?) { self.os = os }

    public var body: some View {
        Image(systemName: Self.symbol(os))
            .imageScale(.large)
            .foregroundStyle(.secondary)
            .frame(width: 28)
            .accessibilityLabel(Self.name(os))
    }

    public static func symbol(_ os: GuestOS?) -> String {
        switch os {
        case .macos?: "apple.logo"
        case .linux?: "terminal"
        case .windows?: "pc"
        case nil: "questionmark.square.dashed"
        }
    }

    public static func name(_ os: GuestOS?) -> String {
        switch os {
        case .macos?: "macOS"
        case .linux?: "Linux"
        case .windows?: "Windows"
        case nil: "Unknown"
        }
    }
}

/// A VM's run state as a coloured dot and a word.
public struct StateDot: View {
    let state: VMRunState?
    let suspended: Bool

    public init(_ state: VMRunState?, suspended: Bool = false) {
        self.state = state
        self.suspended = suspended
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Self.color(state, suspended: suspended)).frame(width: 7, height: 7)
            Text(Self.label(state, suspended: suspended)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("State: \(Self.label(state, suspended: suspended))")
    }

    public static func label(_ state: VMRunState?, suspended: Bool = false) -> String {
        if suspended, state == nil || state == .stopped { return "Suspended" }
        return switch state {
        case nil, .stopped?: "Stopped"
        case .starting?: "Starting"
        case .running?: "Running"
        case .paused?: "Paused"
        case .suspending?: "Suspending"
        case .stopping?: "Stopping"
        case .error?: "Error"
        }
    }

    static func color(_ state: VMRunState?, suspended: Bool = false) -> Color {
        if suspended, state == nil || state == .stopped { return .blue }
        return switch state {
        case .running?: .green
        case .paused?, .suspending?, .starting?, .stopping?: .orange
        case .error?: .red
        case nil, .stopped?: .gray
        }
    }
}

/// Bytes as Finder shows them ("12.3 GB").
public struct ByteSizeText: View {
    let bytes: UInt64?

    public init(_ bytes: UInt64?) { self.bytes = bytes }

    public var body: some View {
        Text(bytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—")
            .monospacedDigit()
    }
}
