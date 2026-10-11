import SwiftUI

/// Shown once, on first launch: what VMPane is, what it does not do with your data, and where to start.
struct OnboardingFlow: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to VMPane").font(.largeTitle.bold())
            item(
                "square.stack.3d.up", "Virtual machines on your Mac",
                "macOS and Linux run on Apple's virtualization; Windows 11 for Arm installs itself from Microsoft's ISO.")
            item(
                "lock.shield", "Your data stays here",
                "VMPane sends no telemetry and no crash reports. VMs, snapshots and settings live in your library folder.")
            item(
                "terminal", "Scriptable, and ready for AI agents",
                "Every VM can be driven from the vmpane command and from AI coding agents over MCP, off until you allow it per VM.")
            HStack {
                Spacer()
                Button("Get Started", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 30).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
