import SwiftUI
import VMPaneCore

/// A system as a tile: a rounded square in the system's own colours with a generic glyph (Apple's system symbol for
/// macOS, a letter for a Linux distribution, four panes for Windows; never another company's logo). Decoration only:
/// the row or card that shows it carries the name.
public struct SystemTile: View {
    let system: System
    let size: CGFloat

    /// The sizes the design uses: 22 and 30 pt in lists, 44 in the inspector, 64 and 72 in detail views.
    public init(_ system: System, size: CGFloat = 30) {
        self.system = system
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        glyph
            .frame(width: size, height: size)
            .background {
                if let brand = system.brand {
                    shape.fill(LinearGradient(colors: [brand.top, brand.bottom], startPoint: .top, endPoint: .bottom))
                        .overlay(shape.strokeBorder(Self.highlight))
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                } else {
                    shape.fill(Color.primary.opacity(0.06))
                        .overlay(shape.strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
            }
            .accessibilityHidden(true)
    }

    /// The light along the top edge.
    static let highlight = LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)

    @ViewBuilder private var glyph: some View {
        switch system.glyph {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
        case .letter(let letter):
            Text(letter).font(.system(size: size * 0.5, weight: .heavy, design: .rounded)).foregroundStyle(.white)
        case .panes:
            let pane = size * 0.19, gap = size * 0.04
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                ForEach(0..<2, id: \.self) { _ in
                    GridRow {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: size * 0.03).fill(.white).frame(width: pane, height: pane)
                        }
                    }
                }
            }
        case .add:
            Image(systemName: "plus").font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

extension SystemTile {
    /// What a tile shows: a system the new-VM sheet makes, a VM's system, or an installer file from this Mac.
    public enum System: Hashable, Sendable {
        case macos, ubuntu, debian, fedora, linux, windows, installer, unknown

        public init(_ card: WizardModel.Card) {
            switch card {
            case .macos: self = .macos
            case .ubuntu: self = .ubuntu
            case .debian: self = .debian
            case .fedora: self = .fedora
            case .windows: self = .windows
            }
        }

        /// A VM's system (nil: unknown, its config unreadable); `distro` (`ubuntu`, `debian`, `fedora`) picks a Linux
        /// VM's colours when known.
        public init(_ os: GuestOS?, distro: String? = nil) {
            switch os {
            case .macos?: self = .macos
            case .windows?: self = .windows
            case .linux?:
                self =
                    switch distro {
                    case "ubuntu": .ubuntu
                    case "debian": .debian
                    case "fedora": .fedora
                    default: .linux
                    }
            case nil: self = .unknown
            }
        }

        var glyph: SystemGlyph {
            switch self {
            case .macos: .symbol("apple.logo")
            case .ubuntu: .letter("U")
            case .debian: .letter("D")
            case .fedora: .letter("F")
            case .linux: .symbol("terminal.fill")
            case .windows: .panes
            case .installer: .add
            case .unknown: .symbol("questionmark")
            }
        }

        /// The tile's colours as 0xRRGGBB, top to bottom (none: the installer's dashed outline). A new distribution adds
        /// one entry. White glyphs keep at least 3:1 against the lighter stop, `top` (`SystemTileTests`).
        var stops: (top: UInt32, bottom: UInt32)? {
            switch self {
            case .macos: (0x5A5A60, 0x2C2C30)
            case .ubuntu: (0xE8622C, 0xC2410C)
            case .debian: (0xC8174A, 0x8A0F33)
            case .fedora: (0x3C6EB4, 0x22437A)
            case .linux: (0x4B5563, 0x1F2937)
            case .windows: (0x1F8BE8, 0x0A5BB0)
            case .unknown: (0x6B6B70, 0x3A3A3E)
            case .installer: nil
            }
        }

        var brand: (top: Color, bottom: Color)? { stops.map { (Self.color($0.top), Self.color($0.bottom)) } }

        static func color(_ rgb: UInt32) -> Color {
            Color(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
        }
    }
}

/// What a tile draws.
enum SystemGlyph { case symbol(String), letter(String), panes, add }

#Preview("Tiles") {
    let systems: [SystemTile.System] = [.macos, .ubuntu, .debian, .fedora, .linux, .windows, .unknown, .installer]
    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
        ForEach([22, 30, 44, 64, 72] as [CGFloat], id: \.self) { size in
            GridRow { ForEach(systems, id: \.self) { SystemTile($0, size: size) } }
        }
    }
    .padding()
}
