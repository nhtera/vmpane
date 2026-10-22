import SwiftUI
import VMPaneCore
import VMPaneHost
import VMPaneUI

/// What the new-VM sheet opens with: a card, or an installer dropped on VMPane (its kind already read).
struct NewVMStart: Identifiable {
    let id = UUID()
    var card: WizardModel.Card?
    var media: (url: URL, kind: InstallMediaKind)?
}

/// The new-VM sheet: system cards with good defaults and one line saying what Create makes (⌘N, then Return makes
/// the last card used); Customize… goes through the steps. On Create the sheet closes and the library shows the VM
/// being made.
struct NewVMWizard: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newVMCard") private var lastCard = WizardModel.Card.ubuntu.rawValue
    @State private var wizard: WizardModel
    @State private var customizing = false

    init(store: LibraryStore, start: NewVMStart = NewVMStart()) {
        self.store = store
        let wizard = WizardModel(existingNames: store.rows.map(\.name) + store.creations.map(\.name))
        if let media = start.media {
            wizard.use(media.url, kind: media.kind)
        } else {
            let saved = UserDefaults.standard.string(forKey: "newVMCard").flatMap(WizardModel.Card.init(rawValue:))
            wizard.choose(start.card ?? saved ?? .ubuntu)
        }
        // A dropped installer that needs more (Windows: the account): the first step still to fill in.
        if start.media != nil, !wizard.canLeave(.summary) {
            wizard.step = wizard.steps.first(where: { $0 != .os && !wizard.canLeave($0) }) ?? .source
        }
        _wizard = State(initialValue: wizard)
        _customizing = State(initialValue: start.media != nil && !wizard.canLeave(.summary))
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
                QuickCreate(wizard: wizard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            }
            Divider()
            footer.padding()
        }
        .frame(width: 680, height: 540)
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
            Spacer()
            if customizing, let problem = wizard.problems(in: wizard.step).first {
                Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if customizing {
                Button("Back") {
                    if wizard.step == customSteps.first { customizing = false } else { wizard.back() }
                }
                if wizard.step == .summary {
                    createButton
                } else {
                    Button("Continue") { wizard.next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!wizard.canLeave(wizard.step))
                }
            } else if wizard.canLeave(.summary) {
                Button("Customize…") { customize() }
                createButton
            } else {
                // Nothing to create yet (Windows needs Microsoft's ISO): Return goes where it is chosen.
                Button("Customize…") { customize() }.keyboardShortcut(.defaultAction)
                Button("Create") {}.disabled(true)
            }
        }
    }

    /// The steps, from the first one still to fill in.
    private func customize() {
        wizard.step = customSteps.first { !wizard.canLeave($0) } ?? customSteps.first ?? .source
        customizing = true
    }

    private var createButton: some View {
        Button("Create") { create() }
            .keyboardShortcut(.defaultAction)
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

/// The sheet's front: the cards, what Create makes, and what is still missing.
private struct QuickCreate: View {
    @Bindable var wizard: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Virtual Machine").font(.title2.bold())
            OSCardGrid(selected: wizard.card) { wizard.choose($0) }
            VStack(alignment: .leading, spacing: 6) {
                Text(wizard.summaryLine).font(.headline).accessibilityLabel("Creates \(wizard.summaryLine)")
                if let note = wizard.generatedAccountNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if let problem = wizard.problems(in: .summary).first {
                    Label(problem, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                Text("AI agents cannot see a VM until you allow it.").font(.callout).foregroundStyle(.secondary)
            }
        }
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
