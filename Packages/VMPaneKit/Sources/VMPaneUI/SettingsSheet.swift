import AppKit
import SwiftUI
import VMPaneCore

/// The VM's settings, as System Settings shows them: its sections in a sidebar (`SettingsModel.section`), one grouped
/// form each. Each setting says whether a change takes effect now ("Live"), at the next start ("Next start"), or
/// simply when saved; Apply sends all changes at once and shows what each one did, whichever section they are in.
public struct SettingsSheet: View {
    /// Its height when the window has room; smaller windows get a shorter sheet (the form scrolls).
    static let idealHeight: CGFloat = 600
    /// Its width when the window has room; a narrower window gets a narrower sheet (the forms wrap).
    static let idealWidth: CGFloat = 720
    static let minimumWidth: CGFloat = 520
    @Bindable var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        SystemTile(SystemTile.System(model.draft.os), size: 32)
                        Text(model.draft.name).font(.headline).lineLimit(2)
                    }
                    .padding([.horizontal, .top], 14)
                    .padding(.bottom, 6)
                    List(selection: Binding(get: { shown }, set: { if let new = $0 { model.section = new } })) {
                        ForEach(sections) { sidebarRow($0).tag($0) }
                    }
                    .listStyle(.sidebar)
                    .accessibilityLabel("Sections")
                }
                .frame(width: 190)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(shown.title).font(.title2.bold()).padding([.horizontal, .top], 20)
                    Form { content(shown) }
                        .formStyle(.grouped)
                }
                .frame(maxWidth: .infinity)
            }
            if model.needsRestart {
                Label("Some changes take effect when the VM next starts.", systemImage: "arrow.clockwise.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.yellow.opacity(0.15))
            }
            Divider()
            HStack {
                Button("Revert") { model.revert() }.vmCapsule(large: false).disabled(!model.hasChanges || model.applying)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).vmCapsule(large: false)
                Button("Apply") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .vmCapsule(prominent: true, large: false)
                    .disabled(!model.hasChanges || model.applying)
            }
            .padding()
        }
        .frame(minWidth: Self.minimumWidth, idealWidth: Self.idealWidth)
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

    /// The section on screen: the chosen one while the VM has it (a Revert can take Port Forwarding away).
    private var shown: SettingsSection { sections.contains(model.section) ? model.section : .general }

    /// A section in the sidebar, marked when it holds a refused change (orange) or one not yet applied (a dot): Apply
    /// and Revert act on every section, not only the one on screen.
    private func sidebarRow(_ section: SettingsSection) -> some View {
        let refused = model.outcomes.contains { SettingsSection.holding($0.key) == section && $0.value == .rejected }
        let pending = model.changedPaths.contains { SettingsSection.holding($0) == section }
        return Label {
            HStack {
                Text(section.title)
                Spacer(minLength: 4)
                if refused {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else if pending {
                    Circle().fill(.tint).frame(width: 7, height: 7)
                }
            }
        } icon: {
            SectionIcon(section.systemImage, color: section.color, size: 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.title)
        .accessibilityValue(refused ? "a change was refused" : pending ? "changed, not applied" : "")
        .accessibilityIdentifier("section \(section.title)")
    }

    /// The sections this VM has (Network and Port Forwarding only with a network; forwards only with NAT).
    private var sections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            switch section {
            case .network: !model.draft.network.isEmpty
            case .portForwarding: model.draft.network.contains { $0.mode == .nat }
            default: true
            }
        }
    }

    @ViewBuilder private func content(_ section: SettingsSection) -> some View {
        switch section {
        case .general: generalSection
        case .hardware: hardwareSection
        case .display: displaySection
        case .sharing: sharingSection
        case .agents: agentsSection
        case .network: networkSection
        case .portForwarding: portForwardingSection
        }
    }

    @ViewBuilder private var generalSection: some View {
        Section {
            row("name") { TextField("Name", text: $model.draft.name) }
        }
    }

    @ViewBuilder private var hardwareSection: some View {
        Section {
            row("cpu.count") {
                Stepper(
                    "Processors: \(model.draft.cpu.count)", value: $model.draft.cpu.count,
                    in: 1...ProcessInfo.processInfo.activeProcessorCount)
            }
            row("memory.mib") {
                Stepper("Memory: \(model.draft.memory.mib >> 10) GB", value: memoryGiB, in: 2...maxMemoryGiB)
            }
        }
    }

    @ViewBuilder private var displaySection: some View {
        Section {
            row("display.widthPx") {
                Picker("Resolution", selection: resolution) {
                    ForEach(resolutionChoices, id: \.self) { size in Text(verbatim: "\(size.width) × \(size.height)").tag(size) }
                }
            }
            row("display.autoResize") { Toggle("Follow the window size", isOn: $model.draft.display.autoResize) }
            if model.draft.os != .macos {
                // A macOS guest scales itself for Retina; Linux and Windows draw what they are given.
                row("display.scaling") {
                    Picker("Scaling", selection: $model.draft.display.scaling) {
                        Text("Sharp (Retina pixels)").tag(DisplayConfig.Scaling.retina)
                        Text("Larger (one pixel per point)").tag(DisplayConfig.Scaling.standard)
                    }
                }
            }
        }
    }

    @ViewBuilder private var sharingSection: some View {
        Section("Clipboard") {
            row("clipboard.mode") {
                Picker("Clipboard", selection: $model.draft.clipboard.mode) {
                    Text("Both ways").tag(ClipboardConfig.Mode.both)
                    Text("Mac to VM").tag(ClipboardConfig.Mode.hostToGuest)
                    Text("VM to Mac").tag(ClipboardConfig.Mode.guestToHost)
                    Text("Off").tag(ClipboardConfig.Mode.off)
                }
            }
            if model.draft.clipboard.mode != .off && model.draft.os != .linux {
                // Linux guests share their clipboard through SPICE: plain text and images only.
                row("clipboard.keepFormatting") {
                    Toggle("Keep text formatting", isOn: $model.draft.clipboard.keepsFormatting)
                }
            }
        }
        Section("Sound") {
            row("audio.output") { Toggle("Sound output", isOn: $model.draft.audio.output) }
            row("audio.input") { Toggle("Microphone", isOn: $model.draft.audio.input) }
        }
        Section("Shared folders") {
            row("shares") { SharedFoldersEditor(shares: $model.draft.shares) }
        }
    }

    @ViewBuilder private var agentsSection: some View {
        AgentPolicySection(
            mcp: $model.draft.mcp, clipboardAllowWithAgents: $model.draft.clipboard.allowWithAgents,
            tampered: model.policyTampered, writableShares: model.draft.shares.contains { !$0.readOnly },
            vm: model.draft.id, name: model.draft.name)
    }

    @ViewBuilder private var networkSection: some View {
        if !model.draft.network.isEmpty {
            Section {
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

    @ViewBuilder private var portForwardingSection: some View {
        Section {
            row("portForwards") {
                PortForwardsEditor(rules: $model.draft.portForwards, statuses: model.portStatuses, listening: model.listening)
            }
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
            .foregroundStyle(.primary)  // the tint is in the capsule: coloured small text is too faint to read
            .background(color.opacity(0.2), in: Capsule())
            .accessibilityLabel("Takes effect: \(text)")
    }
}

/// The VM's shared folders (under the Sharing section's "Shared folders"): add with a folder picker; per row,
/// read-only or not, and remove.
struct SharedFoldersEditor: View {
    @Binding var shares: [Extensible<ShareConfig>]

    var body: some View {
        VStack(alignment: .leading) {
            ForEach($shares, id: \.id) { $share in
                HStack {
                    Label(share.hostPath, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle("Read only", isOn: $share.readOnly)
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Read only: \(share.name)")
                        .help("The VM can read this folder but not change it")
                    Button("Remove", systemImage: "minus.circle") { shares.removeAll { $0.id == share.id } }
                        .accessibilityLabel("Remove \(share.name)")
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
