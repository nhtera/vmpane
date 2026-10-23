import SwiftUI
import VMPaneCore
import VMPaneUI

/// A VM being made, in the library's list: its stage and progress with Cancel, or why it failed with Retry and Remove.
struct CreationRow: View {
    let store: LibraryStore
    let creation: LibraryStore.Creation

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                .overlay { Image(systemName: "display").imageScale(.large).foregroundStyle(.tertiary) }
                .overlay(alignment: .bottomTrailing) { SystemTile(SystemTile.System(creation.os), size: 22).padding(4) }
                .frame(width: 96, height: 60)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(creation.name).font(.headline).lineLimit(1)
                if let failure = creation.failure {
                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
                    HStack {
                        Button("Retry") { store.retryCreation(creation.id) }
                        Button("Remove") { store.forgetCreation(creation.id) }
                    }
                    .controlSize(.small)
                } else {
                    Text(creation.stage).font(.caption).foregroundStyle(.secondary)
                    if let fraction = creation.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
            if creation.failure == nil {
                Button {
                    store.cancelCreation(creation.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop creating this VM")
                .accessibilityLabel("Cancel creating \(creation.name)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(creation.failure == nil ? "\(creation.name), \(creation.stage)" : "\(creation.name), could not be created")
    }
}
