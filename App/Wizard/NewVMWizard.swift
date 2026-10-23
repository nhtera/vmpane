import SwiftUI
import UniformTypeIdentifiers
import VMPaneCore
import VMPaneHost
import VMPaneUI

/// What the new-VM sheet opens with: a card, or an installer dropped on VMPane (its kind already read).
struct NewVMStart: Identifiable {
    let id = UUID()
    var card: WizardModel.Card?
    var media: (url: URL, kind: InstallMediaKind)?
}

/// The new-VM sheet: the systems in a list and the chosen one's detail, with good defaults (⌘N, then Return makes the
/// last system used); Customize… goes through the steps, and "Installer file…" takes an .iso or .ipsw from this Mac.
/// On Create the sheet closes and the library shows the VM being made.
struct NewVMWizard: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newVMCard") private var lastCard = WizardModel.Card.ubuntu.rawValue
    @State private var wizard: WizardModel
    @State private var customizing = false
    @State private var choice: SystemChoice?
    /// Why the installer file chosen here cannot be used.
    @State private var fileProblem: String?
    /// An installer file is being read (an ISO is mounted for a moment).
    @State private var reading = false

    init(store: LibraryStore, start: NewVMStart = NewVMStart()) {
        self.store = store
        let wizard = WizardModel(existingNames: store.rows.map(\.name) + store.creations.map(\.name))
        if let media = start.media {
            wizard.use(media.url, kind: media.kind)
        } else {
            let saved = UserDefaults.standard.string(forKey: "newVMCard").flatMap(WizardModel.Card.init(rawValue:))
            wizard.choose(start.card ?? saved ?? .ubuntu)
        }
        // A dropped installer goes through the steps: the first one still to fill in (Windows: the account), or the
        // summary.
        if start.media != nil { wizard.step = Self.firstOpenStep(of: wizard) }
        _wizard = State(initialValue: wizard)
        _customizing = State(initialValue: start.media != nil)
        // A file is its own row, whatever system it holds.
        _choice = State(initialValue: start.media != nil ? .installer : wizard.card.map(SystemChoice.card))
    }

    var body: some View {
        VStack(spacing: 0) {
            if customizing {
                StepHeader(steps: customSteps, current: wizard.step).padding()
                Divider()
                stepView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("New Virtual Machine").font(.headline).padding([.horizontal, .top], 16).padding(.bottom, 4)
                        // Never nothing: ⌘-click on the chosen row keeps it.
                        SystemList(selection: Binding(get: { choice }, set: { if let new = $0 { choice = new } }), catalogs: .bundled)
                    }
                    .frame(width: 250)
                    Divider()
                    SystemDetail(wizard: wizard, choice: choice, catalogs: .bundled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding()
        }
        .frame(width: 780, height: 560)
        .onChange(of: choice) { _, choice in
            fileProblem = nil
            // A row chooses its system again unless it is already what Create makes (keeping a picked version).
            if case .card(let card)? = choice, card != wizard.card || wizard.installerFile != nil { wizard.choose(card) }
        }
        .onDisappear { wizard.clearSecrets() }
    }

    /// The steps after the card (the card chose the system).
    private var customSteps: [WizardModel.Step] { wizard.steps.filter { $0 != .os } }

    @ViewBuilder private var stepView: some View {
        switch wizard.step {
        case .os, .source: SourceStep(wizard: wizard)
        case .account: AccountStep(wizard: wizard)
        case .resources: ResourcesStep(wizard: wizard)
        case .name: NameStep(wizard: wizard)
        case .integrations: IntegrationsStep(wizard: wizard)
        case .summary: SummaryStep(wizard: wizard)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .vmCapsule()
            Spacer()
            if reading {
                ProgressView().controlSize(.small)
                Text("Reading the installer…").font(.caption).foregroundStyle(.secondary)
            } else if let problem = customizing ? wizard.problems(in: wizard.step).first : fileProblem {
                Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if customizing {
                Button("Back") {
                    if wizard.step == customSteps.first { customizing = false } else { wizard.back() }
                }
                .vmCapsule()
                if wizard.step == .summary {
                    createButton
                } else {
                    Button("Continue") { wizard.next() }
                        .keyboardShortcut(.defaultAction)
                        .vmCapsule(prominent: true)
                        .disabled(!wizard.canLeave(wizard.step))
                }
            } else if choice == .installer, wizard.installerFile == nil {
                Button("Choose File…") { chooseInstaller() }.keyboardShortcut(.defaultAction).vmCapsule(prominent: true)
                disabledCreate
            } else if wizard.canLeave(.summary) {
                if choice == .installer { Button("Choose File…") { chooseInstaller() }.vmCapsule() }
                Button("Customize…") { customize() }.vmCapsule()
                createButton
            } else {
                // Nothing to create yet (Windows needs Microsoft's ISO): Return goes where it is chosen.
                Button("Customize…") { customize() }.keyboardShortcut(.defaultAction).vmCapsule(prominent: true)
                disabledCreate
            }
        }
        .disabled(reading)
    }

    private var disabledCreate: some View { Button("Create") {}.vmCapsule().disabled(true) }

    /// The steps, from the first one still to fill in.
    private func customize() {
        wizard.step = customSteps.first { !wizard.canLeave($0) } ?? customSteps.first ?? .source
        customizing = true
    }

    /// The first step after the system that still needs something, else the summary.
    private static func firstOpenStep(of wizard: WizardModel) -> WizardModel.Step {
        wizard.steps.first { $0 != .os && !wizard.canLeave($0) } ?? .summary
    }

    /// An installer from this Mac, read like one dropped on the library (an ISO is mounted for a moment, off the main
    /// thread), then the steps from the first one still open; or why VMPane cannot use it.
    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["iso", "ipsw"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a Linux or Windows 11 Arm64 ISO, or a macOS restore image (.ipsw)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reading = true
        Task {
            defer { reading = false }
            do {
                let kind = try await Blocking.run { try InstallMediaKind.detect(url) }
                guard choice == .installer else { return }  // the person chose a system meanwhile
                wizard.use(url, kind: kind)
                wizard.step = Self.firstOpenStep(of: wizard)
                customizing = true
            } catch {
                fileProblem = String(describing: error)
            }
        }
    }

    private var createButton: some View {
        Button("Create") { create() }
            .keyboardShortcut(.defaultAction)
            .vmCapsule(prominent: true)
            .disabled(!wizard.canLeave(.summary))
    }

    private func create() {
        guard let request = wizard.request() else { return }
        if let card = wizard.card { lastCard = card.rawValue }
        store.create(request)
        wizard.clearSecrets()
        dismiss()
    }
}

/// Where the sheet is in its steps.
private struct StepHeader: View {
    let steps: [WizardModel.Step]
    let current: WizardModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { step in
                Text(step.title)
                    .font(.caption.weight(step == current ? .semibold : .regular))
                    .foregroundStyle(step == current ? .primary : .secondary)
                if step != steps.last { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count): \(current.title)")
        .accessibilityAddTraits(.isStaticText)  // read as text: without a role VoiceOver cannot say what it is
    }
}
