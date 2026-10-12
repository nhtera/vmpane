import AppKit
import SwiftUI
import VMPaneCore

/// The VM window's content: the guest display (VZ's view or the SPICE view, kept as the same `NSView` so
/// capture and input still find it), an overlay while the guest system installs, and the window toolbar.
public struct VMWindowView: View {
    let display: NSView
    @Bindable var model: HelperViewModel
    /// Sends ⌘-shortcuts to the guest (true) or leaves them with the Mac; nil when the display cannot.
    let captureKeys: (@MainActor (Bool) -> Void)?
    @State private var settings: SettingsModel?
    @State private var snapshots: SnapshotsModel?
    @State private var capturing = false
    @State private var hud = false
    @State private var confirmingCancelInstall = false
    /// The content's height: sheets fit in it instead of hanging below a small window.
    @State private var room: CGFloat = 600

    public init(display: NSView, model: HelperViewModel, captureKeys: (@MainActor (Bool) -> Void)? = nil) {
        self.display = display
        self.model = model
        self.captureKeys = captureKeys
    }

    private var capture: Binding<Bool> {
        Binding(
            get: { capturing },
            set: { captured in
                capturing = captured
                captureKeys?(captured)
                withAnimation { hud = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { hud = false }
                }
            })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    public var body: some View {
        ZStack {
            DisplayHost(view: display)
                .accessibilityLabel("Virtual machine display")
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty, model.state == .running, model.transfer == nil else { return false }
                    Task { await model.drop(files) }
                    return true
                }
            if let install = model.install, install.isActive {
                InstallProgressOverlay(
                    progress: install, os: model.os, cancel: model.os == .windows ? { confirmingCancelInstall = true } : nil)
            } else if model.state == .stopped || model.state == .error {
                StoppedOverlay(model: model)
            }
            if let transfer = model.transfer {
                TransferHUD(transfer: transfer) { Task { await model.cancelDrop() } }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
            }
            if hud {
                CaptureHUD(capturing: capturing)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { room = $0 }
        .task { await model.watchInput() }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { model.notice = nil }
        }
        .toolbar {
            VMToolbar(model: model)
            if captureKeys != nil {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Capture Keyboard", systemImage: "command", isOn: capture)
                        .help(capturing ? "Give ⌘-shortcuts back to the Mac" : "Send ⌘-shortcuts (⌘-Tab, ⌘Q…) to the VM")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Snapshots", systemImage: "clock.arrow.circlepath") { snapshots = model.snapshotsModel() }
                    .help("Take, restore and delete snapshots")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "slider.horizontal.3") {
                    Task { settings = await model.loadSettings() }
                }
                .help("Change this VM's settings")
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .navigationTitle(model.name ?? "")
        // A rename (or any saved change) shows in the title and the toolbar once the sheet closes.
        .sheet(
            isPresented: Binding(get: { settings != nil }, set: { if !$0 { settings = nil } }),
            onDismiss: { Task { await model.refresh() } },
            content: {
                if let settings { SettingsSheet(model: settings).frame(height: fitted(SettingsSheet.idealHeight)) }
            }
        )
        .sheet(isPresented: Binding(get: { snapshots != nil }, set: { if !$0 { snapshots = nil } })) {
            if let snapshots {
                SnapshotsSheet(model: snapshots, running: model.state == .running || model.state == .paused)
                    .frame(height: fitted(SnapshotsSheet.idealHeight))
            }
        }
        .alert("Cancel the Windows installation?", isPresented: $confirmingCancelInstall) {
            Button("Keep Installing", role: .cancel) {}
            Button("Cancel Installation", role: .destructive) { Task { await model.cancelInstall() } }
        } message: {
            Text("The VM stops, and the installer and its answer file (with the password) are removed from it.")
        }
        .alert("The VM could not do that", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    /// A sheet's height in this window: its own when there is room, else the window's (it scrolls).
    private func fitted(_ ideal: CGFloat) -> CGFloat { min(ideal, max(VMWindowContent.minimumHeight - 12, room - 12)) }
}

/// Puts `VMWindowView` into a display window, with its toolbar bridged into the window's title bar.
@MainActor
public enum VMWindowContent {
    /// The smallest content height, so the sheets still fit (they scroll below their own height).
    static let minimumHeight: CGFloat = 340

    public static func install(
        in window: NSWindow, display: NSView, model: HelperViewModel, captureKeys: (@MainActor (Bool) -> Void)? = nil
    ) {
        let hosting = NSHostingController(rootView: VMWindowView(display: display, model: model, captureKeys: captureKeys))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []  // the window keeps its size and aspect; SwiftUI does not resize it
        let size = window.contentLayoutRect.size
        window.contentViewController = hosting
        window.setContentSize(size)
        window.toolbarStyle = .unified
        let aspect = window.contentAspectRatio
        let width = aspect.height > 0 ? minimumHeight * aspect.width / aspect.height : minimumHeight * 4 / 3
        window.contentMinSize = NSSize(width: width, height: minimumHeight)
        if size.height < minimumHeight { window.setContentSize(window.contentMinSize) }
    }
}

private struct DisplayHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The toolbar: power, pause/resume, suspend, snapshot, screenshot, agent status.
struct VMToolbar: ToolbarContent {
    let model: HelperViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.can(.start) {
                button(
                    model.suspended ? "Resume" : "Start", "play.fill", .start,
                    help: model.suspended ? "Resume the VM where it was suspended" : "Start the VM")
            } else {
                button("Shut Down", "power", .shutDown, help: "Shut down the guest (the power button)")
                    .keyboardShortcut(".", modifiers: .command)
            }
            if model.can(.resume) {
                button("Resume", "play.circle", .resume, help: "Resume the paused VM")
            } else {
                button("Pause", "pause.circle", .pause, help: "Pause the VM")
            }
            button("Suspend", "moon.zzz", .suspend, help: "Save the VM's state and stop it")
            button("Snapshot", "camera.aperture", .snapshot, help: "Take a live snapshot")
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Screenshot", systemImage: "camera.viewfinder") {
                let desktop =
                    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
                Task { await model.screenshot(to: desktop) }
            }
            .help("Save a screenshot of the VM to the Desktop")
            .disabled(model.state != .running && model.state != .paused)
        }
        ToolbarItem(placement: .status) {
            AudioIndicators(output: model.audioOutput, input: model.audioInput, inputInUse: model.inputInUse)
        }
        ToolbarItem(placement: .status) {
            Label(
                model.agentConnected ? "Agent connected" : "No agent",
                systemImage: model.agentConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(model.agentConnected ? .green : .secondary)
            .help(model.agentConnected ? "The VMPane guest agent is connected" : "The VMPane guest agent is not connected")
        }
    }

    private func button(_ title: String, _ symbol: String, _ action: HelperViewModel.Action, help: String) -> some View {
        Button(title, systemImage: symbol) { Task { await model.perform(action) } }
            .help(help)
            .disabled(!model.can(action))
    }
}

/// While macOS or Windows installs (the guest needs no input): what is happening and how far along, and for
/// Windows a way to stop.
struct InstallProgressOverlay: View {
    let progress: HelperViewModel.InstallProgress
    let os: GuestOS?
    /// Asks to cancel the install (Windows), when it can be.
    let cancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                Text(os.map { "Installing \(OSBadge.name($0))" } ?? "Installing").font(.headline)
                ProgressView(value: Double(progress.percent), total: 100)
                Text(progress.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("You can leave this running; VMPane restarts the VM when it is done.").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let cancel {
                Button("Cancel Install…", action: cancel)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A stopped VM's window: a big start button over the last frame.
struct StoppedOverlay: View {
    let model: HelperViewModel

    var body: some View {
        Button {
            Task { await model.perform(.start) }
        } label: {
            Label(model.suspended ? "Resume" : "Start", systemImage: "play.circle.fill").font(.title)
        }
        .buttonStyle(.borderless)
        .padding(16)
        .background(.regularMaterial, in: Capsule())
        .disabled(!model.can(.start))
    }
}

/// Says where ⌘-shortcuts go, for a moment after the keyboard capture changes.
struct CaptureHUD: View {
    let capturing: Bool

    var body: some View {
        Label(
            capturing
                ? "⌘-shortcuts go to the VM. Click ⌘ in the toolbar to give them back."
                : "⌘-shortcuts stay with the Mac.",
            systemImage: capturing ? "command.circle.fill" : "command.circle"
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Files being copied into the guest: which one, and how far along.
struct TransferHUD: View {
    let transfer: HelperViewModel.Transfer
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Copying “\(transfer.file)” into the VM").font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Stop", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop copying (what was copied so far is removed from the VM)")
            }
            if transfer.bytesTotal > 0 {
                ProgressView(value: transfer.fraction)
                Text(
                    "\(ByteCountFormatter.string(fromByteCount: transfer.bytesDone, countStyle: .file)) of "
                        + ByteCountFormatter.string(fromByteCount: transfer.bytesTotal, countStyle: .file)
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Sound passed to the VM: the speaker and microphone as set (changed in Settings, from the next start), and a
/// dot while the Mac's input device is in use.
struct AudioIndicators: View {
    let output: Bool
    let input: Bool
    let inputInUse: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: output ? "speaker.wave.2.fill" : "speaker.slash")
                .foregroundStyle(output ? .primary : .secondary)
                .help(output ? "The VM plays sound on this Mac" : "The VM's sound is off")
                .accessibilityLabel(output ? "Sound on" : "Sound off")
            Image(systemName: input ? "mic.fill" : "mic.slash")
                .foregroundStyle(input ? .primary : .secondary)
                .overlay(alignment: .topTrailing) {
                    if input && inputInUse { Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 2, y: -2) }
                }
                .help(input ? (inputInUse ? "Microphone on — the input device is in use" : "Microphone on") : "Microphone off")
                .accessibilityLabel(input ? (inputInUse ? "Microphone on, input device in use" : "Microphone on") : "Microphone off")
        }
    }
}
