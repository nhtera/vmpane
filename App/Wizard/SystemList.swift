import SwiftUI
import VMPaneHost
import VMPaneUI

/// A row of the new-VM sheet's system list: a system VMPane makes, or an installer file from this Mac.
enum SystemChoice: Hashable {
    case card(WizardModel.Card)
    case installer
}

/// The new-VM sheet's left side: the systems in sections (macOS, Linux, Windows, Other), each a tile, its name and the
/// version Create makes. Arrow keys move the choice; Return still creates (the sheet's default button).
struct SystemList: View {
    @Binding var selection: SystemChoice?
    let catalogs: WizardModel.Catalogs
    /// The list takes keyboard focus when the sheet opens: arrow keys move the choice at once.
    @FocusState private var focused: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(WizardModel.CardGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.cards) { card in
                        row(SystemTile.System(card), card.title, card.versionText(in: catalogs)).tag(SystemChoice.card(card))
                    }
                }
            }
            Section("Other") {
                row(.installer, "Installer file…", ".iso or .ipsw on this Mac").tag(SystemChoice.installer)
            }
        }
        .listStyle(.sidebar)
        .focused($focused)
        // After AppKit gives the sheet's first control focus, which happens after onAppear.
        .task { focused = true }
        .accessibilityLabel("Systems")
    }

    private func row(_ system: SystemTile.System, _ title: String, _ version: String?) -> some View {
        HStack(spacing: 10) {
            SystemTile(system, size: 30).accessibilityHidden(true)  // the title names the system
            // The words alone are the row's element: with the tile inside its frame the audit samples the tile's pixels.
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                // In the primary colour: the secondary one on the sidebar's material is too faint for small text.
                if let version { Text(version).font(.caption) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("system \(title)")
        }
        .padding(.vertical, 3)
    }
}
