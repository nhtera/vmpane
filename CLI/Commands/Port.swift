import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

/// Port forwards, changed through `vm.settings.apply` and listed by `vm.ports.list`, like the app does it.
struct Port: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Forward ports from this Mac to a VM.", subcommands: [PortList.self, PortAdd.self, PortRemove.self])
}

private func forwards(_ session: HelperDiscovery.Session) async throws -> [JSONValue] {
    guard case .array(let rules)? = try await session.client.call(ControlMethod.vmSettingsGet.rawValue)["portForwards"] else { return [] }
    return rules
}

private func apply(_ rules: [JSONValue], _ session: HelperDiscovery.Session) async throws {
    let result = try await session.client.call(ControlMethod.vmSettingsApply.rawValue, params: ["patch": ["portForwards": .array(rules)]])
    if result["fields"]?["portForwards"] == "rejected" {
        throw RPCError(.invalidParams, result["reasons"]?["portForwards"]?.stringValue ?? "the forward was refused")
    }
}

struct PortList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List a VM's port forwards and their state.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            let session = try await CLI.connector.connectLaunching(try CLI.item(vm))
            defer { session.client.close() }
            let listed = try await session.client.call(ControlMethod.vmPortsList.rawValue)
            guard case .array(let rules)? = listed["rules"] else { return }
            CLI.print(listed, json: output.json) {
                OutputFormatter.table(
                    ["ID", "PROTO", "MAC", "VM", "STATE"],
                    rules.map { rule in
                        [
                            rule["id"]?.stringValue ?? "", rule["proto"]?.stringValue ?? "",
                            "\(rule["hostAddress"]?.stringValue ?? ""):\(rule["hostPort"]?.intValue ?? 0)",
                            "\(rule["guestPort"]?.intValue ?? 0)",
                            [rule["status"]?.stringValue, rule["reason"]?.stringValue].compactMap { $0 }.joined(separator: ": "),
                        ]
                    })
            }
        }
    }
}

struct PortAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Forward a port: MAC_PORT:VM_PORT, with /udp for UDP (e.g. 8080:80, 5353:53/udp).")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Argument(help: "MAC_PORT:VM_PORT[/udp]") var mapping: String
    @Flag(help: "Listen on every network interface of this Mac, not just on this Mac (others can then connect).")
    var allInterfaces = false

    func run() async throws {
        try await CLI.guarded {
            let (proto, spec) =
                mapping.hasSuffix("/udp")
                ? ("udp", mapping.dropLast(4)) : ("tcp", mapping.hasSuffix("/tcp") ? mapping.dropLast(4) : Substring(mapping))
            let ports = spec.split(separator: ":").compactMap { Int($0) }
            guard ports.count == 2 else { throw RPCError(.invalidParams, "give MAC_PORT:VM_PORT, e.g. 8080:80") }
            let session = try await CLI.connector.connectLaunching(try CLI.item(vm))
            defer { session.client.close() }
            var rules = try await forwards(session)
            let used = Set(rules.compactMap { $0["id"]?.stringValue })
            let id = (1...).lazy.map { "pf-\($0)" }.first { !used.contains($0) } ?? "pf"
            rules.append([
                "id": .string(id), "proto": .string(proto), "hostAddress": allInterfaces ? "0.0.0.0" : "127.0.0.1",
                "hostPort": .int(Int64(ports[0])), "guestPort": .int(Int64(ports[1])), "origin": "user",
            ])
            try await apply(rules, session)
            print(id)
        }
    }
}

struct PortRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a port forward (by id, or by its Mac port).")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Argument(help: "The forward's id, or its Mac port.") var forward: String

    func run() async throws {
        try await CLI.guarded {
            let session = try await CLI.connector.connectLaunching(try CLI.item(vm))
            defer { session.client.close() }
            let rules = try await forwards(session)
            let kept = rules.filter { $0["id"]?.stringValue != forward && $0["hostPort"]?.intValue.map(String.init) != forward }
            guard kept.count < rules.count else { throw RPCError(.invalidParams, "no forward \(forward.debugDescription)") }
            try await apply(kept, session)
        }
    }
}
