import SwiftUI
import UniformTypeIdentifiers
import VMPaneCore
import VMPaneHost
import VMPaneUI

/// Import a Parallels VM: what VMPane read from the `.pvm`, the name and system to confirm, what will not come
/// along (snapshots, the TPM), then the disk conversion with its progress. The `.pvm` is left as it was.
struct ImportParallelsSheet: View {
    let store: LibraryStore
    let pvm: URL
    @Environment(\.dismiss) private var dismiss
    @State private var parallels: ParallelsVM?
    @State private var problem: String?
    @State private var name = ""
    @State private var os = GuestOS.linux
    @State private var progress: Double?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import “\(pvm.deletingPathExtension().lastPathComponent)” from Parallels").font(.title3.weight(.semibold))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if let parallels {
                Form {
                    TextField("Name", text: $name)
                    Picker("System", selection: $os) {
                        Text("Linux").tag(GuestOS.linux)
                        Text("Windows").tag(GuestOS.windows)
                    }
                    LabeledContent("Processors", value: parallels.cpuCount.map(String.init) ?? "as VMPane suggests")
                    LabeledContent("Memory", value: parallels.memoryMiB.map { "\($0 >> 10) GB" } ?? "as VMPane suggests")
                    if parallels.disks.count > 1 {
                        Text("Only the first hard disk is imported (\(parallels.disks.count) found).").font(.caption)
                    }
                }
                .formStyle(.grouped)
                .disabled(progress != nil)
                if os == .windows {
                    Label(
                        "Windows will ask for its BitLocker recovery key at the first start if BitLocker is on (the TPM stays with "
                            + "Parallels), and may ask to be activated again. Have the key ready.",
                        systemImage: "key.fill"
                    )
                    .font(.callout)
                }
                Text("Afterwards: remove Parallels Tools in the guest and install VMPane's guest tools.").font(.caption).foregroundStyle(
                    .secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            if let progress {
                ProgressView("Converting the disk…", value: progress)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if let work { work.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parallels == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || progress != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await read() }
    }

    private func read() async {
        do {
            let found = try await Blocking.run { [pvm] in try ParallelsVM.read(pvm) }
            _ = try await Blocking.run { [disk = found.disks[0]] in try ParallelsDisk.read(disk) }  // refuse early
            parallels = found
            name = found.name
            os = found.os ?? .linux
        } catch {
            problem = ErrorText.readable(error)
        }
    }

    private func start() {
        let qemuImg = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/qemu/bin/qemu-img")
        progress = 0
        work = Task {
            defer { work = nil }
            do {
                try await store.importParallels(pvm, name: name, os: os, qemuImg: qemuImg) { value in
                    Task { @MainActor in progress = value }
                }
                dismiss()
            } catch is CancellationError {
                progress = nil
            } catch {
                progress = nil
                problem = ErrorText.readable(error)
            }
        }
    }
}

extension UTType {
    /// Parallels Desktop's virtual machine bundle.
    static let parallelsVM = UTType(filenameExtension: "pvm", conformingTo: .package) ?? .package
}
