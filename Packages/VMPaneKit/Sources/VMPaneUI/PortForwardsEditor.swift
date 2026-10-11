import SwiftUI
import VMPaneCore

/// The VM's port forwards: one row per rule with its state, remove per row, add through a short form. A rule on
/// all interfaces exposes the guest to the network, so it is a separate, explained choice.
struct PortForwardsEditor: View {
    @Binding var rules: [Extensible<PortForwardConfig>]
    let statuses: [String: SettingsModel.PortStatus]
    var listening: [SettingsModel.ListeningPort] = []
    @State private var adding = false

    /// Listening guest ports no rule forwards yet.
    private var suggestions: [SettingsModel.ListeningPort] {
        listening.filter { port in !rules.contains { $0.proto == port.proto && $0.guestPort == port.port } }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Port forwarding")
            ForEach(rules, id: \.id) { rule in
                HStack {
                    PortStatusDot(status: statuses[rule.id])
                    Text(Self.describe(rule.fields)).monospacedDigit()
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { rules.removeAll { $0.id == rule.id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .accessibilityElement(children: .combine)
            }
            if !suggestions.isEmpty {
                Text("The VM listens on").font(.caption).foregroundStyle(.secondary)
                ForEach(suggestions, id: \.self) { port in
                    HStack {
                        Text("\(port.proto.rawValue.uppercased()) \(port.port)" + (port.process.map { " (\($0))" } ?? "")).monospacedDigit()
                        Spacer()
                        Button("Forward") { forward(port) }.buttonStyle(.borderless)
                    }
                }
            }
            Button("Add Port Forward…") { adding = true }
                .popover(isPresented: $adding) { AddPortForward(rules: $rules) { adding = false } }
        }
    }

    /// Forwards a listening guest port from the same port on this Mac (privileged ones from 10000 up).
    private func forward(_ port: SettingsModel.ListeningPort) {
        let used = Set(rules.map(\.id))
        let id = (1...).lazy.map { "pf-\($0)" }.first { !used.contains($0) } ?? "pf"
        let host = port.port >= 1024 ? port.port : port.port + 10000
        let rule = PortForwardConfig(
            id: id, proto: port.proto, hostAddress: "127.0.0.1", hostPort: host, guestPort: port.port, origin: .user)
        if (try? PortRule.rules(rules + [Extensible(rule)])) != nil { rules.append(Extensible(rule)) }
    }

    /// "TCP 127.0.0.1:8080 → guest 80".
    static func describe(_ rule: PortForwardConfig) -> String {
        let host = rule.hostAddress.contains(":") ? "[\(rule.hostAddress)]" : rule.hostAddress
        return "\(rule.proto.rawValue.uppercased()) \(host):\(rule.hostPort) → guest \(rule.guestPort)"
    }
}

private struct PortStatusDot: View {
    let status: SettingsModel.PortStatus?

    var body: some View {
        let (color, label): (Color, String) =
            switch status?.state {
            case "listening": (.green, "Forwarding")
            case "blocked": (.orange, status?.reason ?? "Blocked by Local Network privacy")
            case "failed": (.red, status?.reason ?? "The host port could not be opened")
            default: (.secondary, "Not active (the VM is not running, or the change is not saved yet)")
            }
        Circle().fill(color).frame(width: 8, height: 8).help(label).accessibilityLabel(label)
    }
}

/// The add form: protocol, ports, and whether other computers may connect.
private struct AddPortForward: View {
    @Binding var rules: [Extensible<PortForwardConfig>]
    let done: () -> Void
    @State private var proto = PortForwardConfig.Proto.tcp
    @State private var hostPort = ""
    @State private var guestPort = ""
    @State private var everyInterface = false

    var body: some View {
        Form {
            Picker("Protocol", selection: $proto) {
                Text("TCP").tag(PortForwardConfig.Proto.tcp)
                Text("UDP").tag(PortForwardConfig.Proto.udp)
            }
            TextField("Mac port", text: $hostPort, prompt: Text("8080"))
            TextField("VM port", text: $guestPort, prompt: Text("80"))
            Toggle("Let other computers on the network connect", isOn: $everyInterface)
            if everyInterface {
                Label(
                    "Anyone who can reach this Mac can reach this port of the VM.", systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let problem = candidate.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done() }
                Button("Add") {
                    if let rule = candidate.rule { rules.append(Extensible(rule)) }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(candidate.rule == nil)
            }
        }
        .padding()
        .frame(width: 340)
    }

    /// The rule the form describes, checked like the helper checks it (and against the VM's other rules).
    private var candidate: (rule: PortForwardConfig?, problem: String?) {
        guard !hostPort.isEmpty, !guestPort.isEmpty else { return (nil, nil) }
        guard let host = Int(hostPort), let guest = Int(guestPort) else { return (nil, "Ports are numbers from 1 to 65535.") }
        let used = Set(rules.map(\.id))
        let id = (1...).lazy.map { "pf-\($0)" }.first { !used.contains($0) } ?? "pf"
        let rule = PortForwardConfig(
            id: id, proto: proto, hostAddress: everyInterface ? "0.0.0.0" : "127.0.0.1", hostPort: host, guestPort: guest, origin: .user)
        do {
            _ = try PortRule.rules(rules + [Extensible(rule)])
            return (rule, nil)
        } catch {
            return (nil, error.reason)
        }
    }
}
