import AppKit
import SwiftUI
import VMPaneCore

/// The VM's settings. Each setting says whether a change takes effect now ("Live"), at the next start ("Next
/// start"), or simply when saved; Apply sends all changes at once and shows what each one did.
public struct SettingsSheet: View {
    /// Its height when the window has room; smaller windows get a shorter sheet (the form scrolls).
    static let idealHeight: CGFloat = 600
    @Bindable var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    row("name") { TextField("Name", text: $model.draft.name) }
                }
                Section("Hardware") {
                    row("cpu.count") {
                        Stepper(
                            "Processors: \(model.draft.cpu.count)", value: $model.draft.cpu.count,
                            in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    }
                    row("memory.mib") {
                        Stepper("Memory: \(model.draft.memory.mib >> 10) GB", value: memoryGiB, in: 2...maxMemoryGiB)
                    }
                }
                Section("Display") {
                    row("display.widthPx") {
                        Picker("Resolution", selection: resolution) {
                            ForEach(resolutionChoices, id: \.self) { size in Text("\(size.width) × \(size.height)").tag(size) }
                        }
                    }
                    row("display.autoResize") { Toggle("Follow the window size", isOn: $model.draft.display.autoResize) }
                    if model.draft.backend == .qemu {
                        // VZ follows the window's backing pixels itself; the SPICE window picks the guest size.
                        row("display.scaling") {
                            Picker("Scaling", selection: $model.draft.display.scaling) {
                                Text("Sharp (Retina pixels)").tag(DisplayConfig.Scaling.retina)
                                Text("Larger (one pixel per point)").tag(DisplayConfig.Scaling.standard)
                            }
                        }
                    }
                }
                Section("Sharing") {
                    row("clipboard.mode") {
                        Picker("Clipboard", selection: $model.draft.clipboard.mode) {
                            Text("Both ways").tag(ClipboardConfig.Mode.both)
                            Text("Mac to VM").tag(ClipboardConfig.Mode.hostToGuest)
                            Text("VM to Mac").tag(ClipboardConfig.Mode.guestToHost)
                            Text("Off").tag(ClipboardConfig.Mode.off)
                        }
                    }
                    row("audio.output") { Toggle("Sound output", isOn: $model.draft.audio.output) }
                    row("audio.input") { Toggle("Microphone", isOn: $model.draft.audio.input) }
                    row("shares") { SharedFoldersEditor(shares: $model.draft.shares) }
                }
                AgentPolicySection(
                    mcp: $model.draft.mcp, clipboardAllowWithAgents: $model.draft.clipboard.allowWithAgents,
                    tampered: model.policyTampered, writableShares: model.draft.shares.contains { !$0.readOnly })
                if model.draft.network.contains(where: { $0.mode == .nat }) {
                    Section("Port Forwarding") {
                        row("portForwards") {
                            PortForwardsEditor(rules: $model.draft.portForwards, statuses: model.portStatuses, listening: model.listening)
                        }
                    }
                }
                if !model.draft.network.isEmpty {
                    Section("Network") {
                        row("network.0.mode") {
                            Picker("Network", selection: $model.draft.network[0].mode) {
                                Text("Shared (NAT)").tag(NetworkConfig.Mode.nat)
                                Text("Bridged").tag(NetworkConfig.Mode.bridged)
                                Text("Off").tag(NetworkConfig.Mode.none)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if model.needsRestart {
                Label("Some changes take effect when the VM next starts.", systemImage: "arrow.clockwise.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.yellow.opacity(0.15))
            }
            Divider()
            HStack {
                Button("Revert") { model.revert() }.disabled(!model.hasChanges || model.applying)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges || model.applying)
            }
            .padding()
        }
        .frame(width: 520)
        .frame(minHeight: 300, idealHeight: Self.idealHeight)
        .task {
            await model.refreshPorts()
            await model.refreshPolicy()
        }
        .alert("Settings not saved", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    /// A setting with its badge (and, after Apply, what happened to it).
    private func row(_ path: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            content()
            Spacer(minLength: 8)
            ApplyModeBadge(kind: SettingsModel.kind(of: path), outcome: model.outcomes[path], reason: model.reasons[path])
        }
    }

    private var maxMemoryGiB: Int { max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 4) }

    private var memoryGiB: Binding<Int> {
        Binding(get: { model.draft.memory.mib >> 10 }, set: { model.draft.memory.mib = $0 << 10 })
    }

    struct Size: Hashable {
        let width: Int
        let height: Int
    }

    static let resolutions = [
        Size(width: 1280, height: 800), Size(width: 1440, height: 900), Size(width: 1920, height: 1200),
        Size(width: 2560, height: 1600), Size(width: 1920, height: 1080), Size(width: 2560, height: 1440),
    ]

    /// The presets, plus the VM's own size when it is not one of them (a picker without its value shows nothing).
    private var resolutionChoices: [Size] {
        let current = Size(width: model.draft.display.widthPx, height: model.draft.display.heightPx)
        return Self.resolutions.contains(current) ? Self.resolutions : [current] + Self.resolutions
    }

    private var resolution: Binding<Size> {
        Binding(
            get: { Size(width: model.draft.display.widthPx, height: model.draft.display.heightPx) },
            set: {
                model.draft.display.widthPx = $0.width
                model.draft.display.heightPx = $0.height
            })
    }
}

/// "Live" or "Next start" before Apply; what happened after.
public struct ApplyModeBadge: View {
    let kind: SettingKind
    let outcome: SettingOutcome?
    let reason: String?

    public var body: some View {
        switch (outcome, kind) {
        case (.applied?, _): badge("Applied", .green)
        case (.nextBoot?, _): badge("Next start", .orange)
        case (.rejected?, _): badge(reason ?? "Refused", .red)
        case (nil, .live): badge("Live", .blue)
        case (nil, .nextBoot): badge("Next start", .secondary)
        default: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Takes effect: \(text)")
    }
}

/// The VM's shared folders: add with a folder picker, remove per row.
struct SharedFoldersEditor: View {
    @Binding var shares: [Extensible<ShareConfig>]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Shared folders")
            ForEach(shares, id: \.id) { share in
                HStack {
                    Label(share.hostPath, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { shares.removeAll { $0.id == share.id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Folder…") { add() }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url, ShareWarning.confirm(url) else { return }
        let id = "share-\((shares.compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1)"
        var name = url.lastPathComponent
        var suffix = 2
        while shares.contains(where: { $0.name == name }) {
            name = "\(url.lastPathComponent) \(suffix)"
            suffix += 1
        }
        shares.append(Extensible(ShareConfig(id: id, name: name, hostPath: url.path, readOnly: false)))
    }
}
