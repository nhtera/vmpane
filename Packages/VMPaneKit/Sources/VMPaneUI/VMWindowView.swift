import AppKit
import SwiftUI
import VMPaneCore

/// The VM window's content: the guest display (VZ's view or the SPICE view, kept as the same `NSView` so
/// capture and input still find it), an overlay while Windows installs, and the window toolbar.
public struct VMWindowView: View {
    let display: NSView
    @Bindable var model: HelperViewModel

    public init(display: NSView, model: HelperViewModel) {
        self.display = display
        self.model = model
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    public var body: some View {
        ZStack {
            DisplayHost(view: display)
                .accessibilityLabel("Virtual machine display")
            if let install = model.install, install.isActive {
                InstallProgressOverlay(progress: install)
            } else if model.state == .stopped || model.state == .error {
                StoppedOverlay(model: model)
            }
        }
        .toolbar { VMToolbar(model: model) }
        .alert("The VM could not do that", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Puts `VMWindowView` into a display window, with its toolbar bridged into the window's title bar.
@MainActor
public enum VMWindowContent {
    public static func install(in window: NSWindow, display: NSView, model: HelperViewModel) {
        let hosting = NSHostingController(rootView: VMWindowView(display: display, model: model))
        hosting.sceneBridgingOptions = [.toolbars]
        let size = window.contentLayoutRect.size
        window.contentViewController = hosting
        window.setContentSize(size)
        window.toolbarStyle = .unified
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
                button("Start", "play.fill", .start, help: "Start the VM")
            } else {
                button("Shut Down", "power", .shutDown, help: "Shut down the guest (the power button)")
            }
            if model.can(.resume) {
                button("Resume", "play.circle", .resume, help: "Resume the paused VM")
            } else {
                button("Pause", "pause.circle", .pause, help: "Pause the VM")
            }
            button("Suspend", "moon.zzz", .suspend, help: "Save the VM's state and stop it")
            button("Snapshot", "camera.aperture", .snapshot, help: "Take a live snapshot")
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

/// While Windows installs (the guest needs no input): what is happening and how far along.
struct InstallProgressOverlay: View {
    let progress: HelperViewModel.InstallProgress

    var body: some View {
        VStack(spacing: 10) {
            Text("Installing Windows").font(.headline)
            ProgressView(value: Double(progress.percent), total: 100)
            Text(progress.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("You can leave this running; VMPane restarts the VM when it is done.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A stopped VM's window: a big start button over the last frame.
struct StoppedOverlay: View {
    let model: HelperViewModel

    var body: some View {
        Button {
            Task { await model.perform(.start) }
        } label: {
            Label("Start", systemImage: "play.circle.fill").font(.title)
        }
        .buttonStyle(.borderless)
        .padding(16)
        .background(.regularMaterial, in: Capsule())
        .disabled(!model.can(.start))
    }
}
