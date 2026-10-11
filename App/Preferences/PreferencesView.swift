import SwiftUI
import VMPaneCore

/// VMPane ▸ Settings: where VMs live, privacy, and backups.
struct PreferencesView: View {
    let paths: VMPanePaths
    @State private var excludeRAM = SharedPreferences.excludeRAMSnapshotsFromBackup
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("VMs are kept in") {
                    Text(paths.defaultLibrary.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([paths.defaultLibrary]) }
            }
            Section {
                Toggle("Keep live snapshots' memory out of Time Machine", isOn: $excludeRAM)
                    .onChange(of: excludeRAM) { _, value in SharedPreferences.excludeRAMSnapshotsFromBackup = value }
            } header: {
                Text("Backups")
            } footer: {
                Text("A live snapshot saves the VM's memory, which can hold passwords and keys. Applies to snapshots taken from now on.")
            }
            Section {
                Text("VMPane sends nothing about you or your VMs anywhere: no telemetry, no crash reports.")
                Button("Show the Welcome Again") { onboarded = false }
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
