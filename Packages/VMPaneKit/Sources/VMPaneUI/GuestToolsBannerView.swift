import SwiftUI
import VMPaneCore

/// How to install the guest tools in a VM without them (or update a macOS VM's by hand), at the top of the window:
/// what to do in the guest, with the one step VMPane can take for it (typing Linux's command, attaching Windows'
/// disc). Never over the guest's screen for long: Not Now closes it, Don't Ask Again for this VM.
struct GuestToolsBannerView: View {
    let banner: GuestToolsBanner
    let model: HelperViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
            } icon: {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.tint)
            }
            Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let command {
                Text(verbatim: command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                actions
                Spacer(minLength: 8)
                Button("Not Now") { withAnimation { model.closeToolsBanner(forever: false) } }
                Button("Don’t Ask Again") { withAnimation { model.closeToolsBanner(forever: true) } }
                    .help("Don’t offer the guest tools for this VM again (VM menu › Install Guest Tools… still does)")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-tools-banner")
    }

    /// The command to run in the guest, shown to read or select.
    private var command: String? {
        switch banner {
        case .install(.linux): HelperViewModel.linuxToolsCommand
        case .install(.windows) where model.guestTools.discAttached: HelperViewModel.windowsToolsCommand
        default: nil
        }
    }

    private var title: String {
        banner == .updateByHand ? "Update VMPane’s guest tools in this VM" : "Install VMPane’s guest tools in this VM"
    }

    /// What to do in the guest, for its system.
    private var detail: String {
        let why = "They let AI agents run commands and share the clipboard and folders; later versions install by themselves."
        switch banner {
        case .updateByHand:
            return "This VM’s guest tools are older than VMPane. In the VM, open Finder › My Shared Files › vmpane-tools, "
                + "then open VMPane Agent.pkg."
        case .install(.macos):
            return "In the VM, open Finder › My Shared Files › vmpane-tools, then open VMPane Agent.pkg. They let AI agents "
                + "run commands and share the clipboard and folders."
        case .install(.linux):
            return "Open a terminal in the VM, then run this (VMPane can type it for you; press Return in the VM). \(why)"
        case .install(.windows):
            return model.guestTools.discAttached
                ? "The disc is attached from the VM’s next start: shut Windows down, start the VM again, then run this in an "
                    + "administrator PowerShell (D: is the VMPANE_TOOLS drive)."
                : "Attach the guest-tools disc, shut Windows down and start the VM again, then run install.ps1 on the "
                    + "VMPANE_TOOLS drive as administrator. \(why)"
        }
    }

    @ViewBuilder private var actions: some View {
        switch banner {
        case .install(.linux):
            Button("Type in the VM") { Task { await model.typeToolsCommand() } }
                .help("Types the command into the VM; press Return there to run it")
            Button("Copy") { model.copyToolsCommand() }
        case .install(.windows) where !model.guestTools.discAttached:
            Button("Attach Tools Disc") { Task { await model.attachToolsDisc() } }
                .help("Attaches the guest-tools disc to this VM from its next start")
        default:
            EmptyView()
        }
    }
}
