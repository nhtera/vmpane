import SwiftUI
import VMPaneCore
import VMPaneHost
import VMPaneUI

/// The new-VM sheet's right side: what Create makes (from the wizard's source, which Customize… or a file can change
/// after the row was chosen), its size and account, and what it still needs.
struct SystemDetail: View {
    @Bindable var wizard: WizardModel
    let choice: SystemChoice?
    let catalogs: WizardModel.Catalogs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text(about).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FactsBox(facts: facts)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if wizard.mcpPolicy == .off {
                    Label("AI agents cannot see this VM until you allow it.", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The row's card, unless the installer row (or a file) is what Create uses.
    private var card: WizardModel.Card? {
        guard case .card(let card)? = choice, wizard.installerFile == nil else { return nil }
        return card
    }

    /// The system Create makes: the catalog image's when there is one (Customize… may have picked another
    /// distribution's), else the row's.
    private var shown: (system: SystemTile.System, title: String) {
        switch wizard.source {
        case .macCatalog?: return (.macos, "macOS")
        case .linuxCatalog(let image)?:
            let distro = image.distro.flatMap(WizardModel.Card.init(rawValue:))
            return (SystemTile.System(.linux, distro: image.distro), distro?.title ?? image.name)
        case .macRestoreImage?, .linuxISO?, .windowsISO?: return (.installer, "Installer File")
        case nil: return card.map { (SystemTile.System($0), $0.title) } ?? (.installer, "Installer File")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            SystemTile(shown.system, size: 72)
            VStack(alignment: .leading, spacing: 8) {
                Text(shown.title).font(.title.bold())
                    .accessibilityIdentifier("system title")
                    .accessibilityValue("Creates \(wizard.summaryLine)")
                HStack(spacing: 10) {
                    version
                    if wizard.isCloudImage {
                        Picker("Edition", selection: $wizard.desktop) {
                            Text("Server").tag(false)
                            Text("Desktop").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// A menu when the row's catalog has more than one image and Create uses one of them; else the version as text.
    @ViewBuilder private var version: some View {
        let images = card?.images(in: catalogs) ?? []
        if images.count > 1, let chosen = wizard.catalogImage, images.contains(chosen) {
            Picker("Version", selection: Binding(get: { chosen.id }, set: { id in images.first { $0.id == id }.map(wizard.pick) })) {
                // Newest first (macOS's catalog lists oldest first).
                ForEach(card == .macos ? images.reversed() : images) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
        } else if let text = versionText {
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var versionText: String? {
        if let file = wizard.installerFile { return file.lastPathComponent }
        if let image = wizard.catalogImage {
            return shown.title == image.name ? nil : WizardModel.Card.dropping(shown.title, from: image.title)
        }
        return card?.versionText(in: catalogs) ?? ".iso or .ipsw on this Mac"
    }

    private var about: String {
        card?.about ?? "Any Linux ISO, a Windows 11 Arm64 ISO or a macOS .ipsw from this Mac. You can also drop one on the library."
    }

    /// What Create still needs; for Windows, where its ISO comes from.
    private var problem: String? {
        guard choice != .installer || wizard.installerFile != nil else { return nil }
        if card == .windows, wizard.source == nil {
            return "Needs Microsoft’s Windows 11 Arm64 ISO. Customize… opens Microsoft’s download page, or picks one you have."
        }
        return wizard.problems(in: .summary).first
    }

    private var facts: [(String, String)] {
        guard card != nil || wizard.installerFile != nil else {
            return [("Processors", "—"), ("Memory", "—"), ("Disk", "—"), ("Account", "Depends on the installer")]
        }
        return [
            ("Processors", "\(wizard.cpuCount)"), ("Memory", "\(wizard.memoryGiB) GB"), ("Disk", "\(wizard.diskGiB) GB"),
            ("Account", account), ("AI agents", wizard.mcpPolicy.title),
        ]
    }

    private var account: String {
        switch wizard.os {
        case .macos?: "Created in Setup Assistant"
        case .windows?: "You choose it in Customize"
        case .linux? where !wizard.isCloudImage: "Created by the installer"
        default: wizard.usesGeneratedPassword ? "\(wizard.userName) · password kept by VMPane" : wizard.userName
        }
    }
}

/// Label–value rows in one rounded box, as grouped forms draw them (our own view: the same on every macOS; a `Form`
/// would scroll on its own inside the detail's scroll view).
private struct FactsBox: View {
    let facts: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Divider().padding(.leading, 12) }
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.0)
                    Spacer(minLength: 12)
                    Text(fact.1).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(fact.0)
                .accessibilityValue(fact.1)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
