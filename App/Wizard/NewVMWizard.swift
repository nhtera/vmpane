import SwiftUI
import VMPaneCore
import VMPaneUI

/// The new-VM wizard, as a sheet over the library: one step at a time, then the create with its progress.
struct NewVMWizard: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var wizard: WizardModel
    @State private var creating = false
    @State private var progress: VMCreator.Progress?
    @State private var failure: String?
    @State private var creation: Task<Void, Never>?

    init(store: LibraryStore) {
        self.store = store
        _wizard = State(initialValue: WizardModel(existingNames: store.rows.map(\.name)))
    }

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(steps: wizard.steps, current: wizard.step)
                .padding()
            Divider()
            Group {
                if creating {
                    CreateProgressView(progress: progress)
                } else {
                    stepView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
            Divider()
            footer.padding()
        }
        .frame(width: 640, height: 520)
        .alert("The VM could not be created", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .onDisappear { wizard.clearSecrets() }
    }

    @ViewBuilder private var stepView: some View {
        switch wizard.step {
        case .os: OSChoiceStep(wizard: wizard)
        case .source: SourceStep(wizard: wizard)
        case .account: AccountStep(wizard: wizard)
        case .resources: ResourcesStep(wizard: wizard)
        case .name: NameStep(wizard: wizard)
        case .integrations: IntegrationsStep(wizard: wizard)
        case .summary: SummaryStep(wizard: wizard)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                // A running create (a download can take long) stops and removes what it made.
                if let creation {
                    creation.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if let problem = wizard.problems(in: wizard.step).first, wizard.step != .os, !creating {
                Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Back") { wizard.back() }
                .disabled(wizard.step == wizard.steps.first || creating)
            if wizard.step == .summary {
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!wizard.canLeave(.summary) || creating)
            } else {
                Button("Continue") { wizard.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!wizard.canLeave(wizard.step))
            }
        }
    }

    private func create() {
        guard let request = wizard.request() else { return }
        creating = true
        let creator = store.makeCreator()
        creation = Task {
            defer { creation = nil }
            do {
                let bundle = try await creator.create(request) { update in
                    Task { @MainActor in progress = update }
                }
                wizard.clearSecrets()
                dismiss()
                await store.didCreate(bundle)
            } catch is CancellationError {
                creating = false
            } catch let error as URLError where error.code == .cancelled {
                creating = false
            } catch {
                creating = false
                failure = String(describing: error)
            }
        }
    }
}

/// Where the wizard is.
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
    }
}

private struct CreateProgressView: View {
    let progress: VMCreator.Progress?

    var body: some View {
        VStack(spacing: 12) {
            switch progress {
            case .downloading(let received, let total)?:
                if let total, total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                } else {
                    ProgressView()
                }
                Text("Downloading the installer… \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))")
            case .preparing?:
                ProgressView()
                Text("Preparing the install…")
            default:
                ProgressView()
                Text("Creating the VM…")
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
