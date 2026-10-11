import SwiftUI
import UniformTypeIdentifiers
import VMPaneCore
import VMPaneHost
import VMPaneUI

/// Step 1: which system.
struct OSChoiceStep: View {
    @Bindable var wizard: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which system do you want to run?").font(.title3)
            HStack(spacing: 12) {
                choice(.macos, "macOS", "Runs on Apple's virtualization. Needs a restore image.")
                choice(.linux, "Linux", "Ubuntu, Debian, Fedora and other arm64 distributions.")
                choice(.windows, "Windows 11", "Windows 11 for Arm, installed for you from Microsoft's ISO.")
            }
        }
    }

    private func choice(_ os: GuestOS, _ title: String, _ detail: String) -> some View {
        Button {
            wizard.os = os
        } label: {
            VStack(spacing: 8) {
                Image(systemName: OSBadge.symbol(os)).font(.system(size: 34))
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(wizard.os == os ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: wizard.os == os ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(wizard.os == os ? .isSelected : [])
    }
}

/// Step 2: where the system comes from.
struct SourceStep: View {
    @Bindable var wizard: WizardModel
    @State private var catalog: [ImageCatalog.Image] = []

    var body: some View {
        Form {
            switch wizard.os {
            case .macos?:
                Section("Restore image") {
                    ForEach(catalog) { image in catalogRow(image, .macCatalog(image)) }
                    fileRow(title: "Choose a restore image (.ipsw)…", types: [UTType(filenameExtension: "ipsw") ?? .data]) {
                        .macRestoreImage($0)
                    }
                }
            case .linux?:
                Section("Download") {
                    ForEach(catalog) { image in catalogRow(image, .linuxCatalog(image)) }
                }
                Section("Or use an ISO you have") {
                    fileRow(title: "Choose an arm64 ISO…", types: [UTType(filenameExtension: "iso") ?? .data]) { .linuxISO($0) }
                }
            case .windows?:
                Section {
                    Text("Download Windows 11 for Arm (ISO) from Microsoft, then choose the file here.")
                    if let page = Links.windowsDownload { Link("Open Microsoft's download page", destination: page) }
                    fileRow(title: "Choose the Windows ISO…", types: [UTType(filenameExtension: "iso") ?? .data]) { .windowsISO($0) }
                }
            case nil:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .task(id: wizard.os) {
            catalog =
                switch wizard.os {
                case .macos?: (try? ImageCatalog.macOS().images) ?? []
                case .linux?: (try? ImageCatalog.linux().images) ?? []
                default: []
                }
        }
    }

    private func catalogRow(_ image: ImageCatalog.Image, _ source: WizardModel.Source) -> some View {
        Button {
            wizard.source = source
        } label: {
            HStack {
                Image(systemName: wizard.source == source ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading) {
                    Text("\(image.name) \(image.version)")
                    Text(ByteCountFormatter.string(fromByteCount: image.sizeBytes, countStyle: .file) + " download")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileRow(title: String, types: [UTType], source: @escaping (URL) -> WizardModel.Source) -> some View {
        HStack {
            Button(title) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = types
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { wizard.source = source(url) }
            }
            Spacer()
            if let chosen = chosenFile { Text(chosen.lastPathComponent).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private var chosenFile: URL? {
        switch wizard.source {
        case .macRestoreImage(let url)?, .linuxISO(let url)?, .windowsISO(let url)?: url
        default: nil
        }
    }
}

/// Windows only: the account Windows Setup creates, and Microsoft's licence.
struct AccountStep: View {
    @Bindable var wizard: WizardModel

    var body: some View {
        Form {
            Section("Your Windows account") {
                TextField("User name", text: $wizard.userName)
                SecureField("Password", text: $wizard.password)
                Picker("Edition", selection: $wizard.edition) {
                    ForEach(["Windows 11 Pro", "Windows 11 Home"], id: \.self) { Text($0) }
                }
            }
            Section {
                Toggle(isOn: $wizard.eulaAccepted) {
                    Text("I accept the Microsoft Software License Terms for Windows 11.")
                }
                if let terms = Links.windowsTerms { Link("Read the license terms", destination: terms) }
            } footer: {
                Text("VMPane installs Windows with Microsoft's generic key for the edition: it installs but is not activated.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Processors, memory, disk.
struct ResourcesStep: View {
    @Bindable var wizard: WizardModel

    var body: some View {
        Form {
            Stepper(value: $wizard.cpuCount, in: 1...wizard.maxCPUs) {
                LabeledContent("Processors", value: "\(wizard.cpuCount) of \(wizard.maxCPUs)")
            }
            Stepper(value: $wizard.memoryGiB, in: 2...wizard.maxMemoryGiB) {
                LabeledContent("Memory", value: "\(wizard.memoryGiB) GB (up to \(wizard.maxMemoryGiB) GB)")
            }
            Stepper(value: $wizard.diskGiB, in: wizard.minDiskGiB...2048, step: 16) {
                LabeledContent("Disk", value: "\(wizard.diskGiB) GB")
            }
            Text("The disk only takes the space the system actually uses.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct NameStep: View {
    @Bindable var wizard: WizardModel

    var body: some View {
        Form {
            TextField("Name", text: $wizard.name)
        }
        .formStyle(.grouped)
    }
}

/// Shared folders, clipboard, sound, Rosetta, and what AI agents may do.
struct IntegrationsStep: View {
    @Bindable var wizard: WizardModel

    var body: some View {
        Form {
            Section("Shared folders") {
                ForEach(wizard.sharedFolders, id: \.self) { folder in
                    HStack {
                        Label(folder.path, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { wizard.sharedFolders.removeAll { $0 == folder } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { addFolder() }
            }
            Section {
                Toggle("Share the clipboard", isOn: $wizard.clipboard)
                Toggle("Sound output", isOn: $wizard.audioOutput)
                Toggle("Microphone", isOn: $wizard.microphone)
                if wizard.os == .linux { Toggle("Rosetta (run x86-64 Linux programs)", isOn: $wizard.rosetta) }
            }
            Section {
                Picker("AI agents (MCP)", selection: $wizard.mcpPolicy) {
                    Text("Off").tag(PolicyLevel.off)
                    Text("Observe").tag(PolicyLevel.observe)
                    Text("Control").tag(PolicyLevel.control)
                    Text("Run commands").tag(PolicyLevel.exec)
                    Text("Administer").tag(PolicyLevel.admin)
                }
            } footer: {
                if wizard.mcpPolicy >= .exec {
                    Text("AI agents connected to VMPane will be able to run commands in this VM.").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !wizard.sharedFolders.contains(url) {
            wizard.sharedFolders.append(url)
        }
    }
}

/// Everything at a glance before creating.
struct SummaryStep: View {
    let wizard: WizardModel

    var body: some View {
        Form {
            LabeledContent("System", value: OSBadge.name(wizard.os))
            LabeledContent("Installer", value: installer)
            if wizard.os == .windows { LabeledContent("Account", value: wizard.userName) }
            LabeledContent("Processors", value: "\(wizard.cpuCount)")
            LabeledContent("Memory", value: "\(wizard.memoryGiB) GB")
            LabeledContent("Disk", value: "\(wizard.diskGiB) GB")
            LabeledContent("Name", value: wizard.name)
            LabeledContent("Shared folders", value: wizard.sharedFolders.isEmpty ? "None" : "\(wizard.sharedFolders.count)")
            ForEach(wizard.problems(in: .summary), id: \.self) { Text($0).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private var installer: String {
        switch wizard.source {
        case .macCatalog(let image)?, .linuxCatalog(let image)?: "\(image.name) \(image.version) (download)"
        case .macRestoreImage(let url)?, .linuxISO(let url)?, .windowsISO(let url)?: url.lastPathComponent
        case nil: "—"
        }
    }
}

private enum Links {
    static let windowsDownload = URL(string: "https://www.microsoft.com/software-download/windows11arm64")
    static let windowsTerms = URL(string: "https://www.microsoft.com/useterms")
}
