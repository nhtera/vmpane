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

// MARK: - Agent levels, one vocabulary

extension PolicyLevel {
    /// What the app, the docs and the site call the level.
    public var title: String {
        switch self {
        case .off: "Off"
        case .observe: "Look only"
        case .control: "Use the screen and keyboard"
        case .exec: "Run commands"
        case .admin: "Full control"
        }
    }

    public var explanation: String {
        switch self {
        case .off: "Agents cannot see this VM."
        case .observe: "Agents can see its state and screenshots."
        case .control: "Agents can also click, type, start, pause and snapshot it."
        case .exec: "Agents can also run commands as the logged-in user and copy files in and out."
        case .admin: "Agents can also run commands as administrator, shut it down and delete snapshots."
        }
    }
}

// MARK: - Surfaces

extension View {
    /// The surface of controls that float over a VM's screen or the library (the agent HUD, overlays): Liquid Glass on
    /// macOS 26, a material before it; opaque with Reduce Transparency or Increase Contrast.
    public func vmGlass(cornerRadius: CGFloat = 12) -> some View {
        modifier(VMGlass(cornerRadius: cornerRadius))
    }
}

struct VMGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape).overlay(shape.strokeBorder(.separator))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(.separator.opacity(0.5)))
        }
    }
}

/// An AI agent at work on a VM: who, written out (never colour alone).
public struct AgentBadge: View {
    let client: String
    let acting: Bool

    public init(client: String, acting: Bool = true) {
        self.client = client
        self.acting = acting
    }

    public var body: some View {
        Label(acting ? "\(client) · acting" : client, systemImage: "sparkles")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .accessibilityLabel(acting ? "\(client) is acting" : "\(client)")
    }
}
