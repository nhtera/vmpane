import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the VMs in the library.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            var rows: [JSONValue] = []
            for item in try CLI.ops.list() {
                let state = await CLI.state(item)
                var row: [String: JSONValue] = [
                    "id": .string(item.id.uuidString), "shortId": .string(ShortID(item.id).rawValue), "state": .string(state),
                    "path": .string(item.bundle.url.path),
                ]
                if let config = item.config {
                    row["name"] = .string(config.name)
                    row["os"] = .string(config.os.rawValue)
                    row["backend"] = .string(config.backend.rawValue)
                }
                if let error = item.error { row["error"] = .string(error) }
                rows.append(.object(row))
            }
            CLI.print(.array(rows), json: output.json) {
                OutputFormatter.table(
                    ["NAME", "ID", "OS", "STATE"],
                    rows.map { row in
                        ["name", "shortId", "os", "state"].map { row[$0]?.stringValue ?? "?" }
                    })
            }
        }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a VM's settings and state.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            let item = try CLI.item(vm)
            guard let config = item.config else { throw RPCError(.invalidState, item.error ?? "the VM's settings cannot be read") }
            let info: JSONValue = [
                "id": .string(config.id.uuidString), "name": .string(config.name), "os": .string(config.os.rawValue),
                "backend": .string(config.backend.rawValue), "state": .string(await CLI.state(item)),
                "cpus": .int(Int64(config.cpu.count)), "memoryMiB": .int(Int64(config.memory.mib)),
                "disks": .array(config.disks.map { ["id": .string($0.id), "sizeGiB": .int(Int64($0.sizeGiB))] }),
                "policy": .string(config.mcp.policy.rawValue), "path": .string(item.bundle.url.path),
            ]
            CLI.print(info, json: output.json) {
                let disks = config.disks.map { "\($0.sizeGiB) GB" }.joined(separator: ", ")
                return OutputFormatter.table(
                    ["", ""],
                    [
                        ["Name", config.name], ["ID", config.id.uuidString], ["System", config.os.rawValue],
                        ["State", info["state"]?.stringValue ?? "?"], ["Processors", "\(config.cpu.count)"],
                        ["Memory", "\(config.memory.mib >> 10) GB"], ["Disks", disks], ["Agent policy", config.mcp.policy.rawValue],
                        ["Location", item.bundle.url.path],
                    ]
                ).split(separator: "\n").dropFirst().joined(separator: "\n")
            }
        }
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print VMPane's version.")
    @OptionGroup var output: OutputOptions

    func run() {
        CLI.print(["version": .string(VMPane.version)], json: output.json) { VMPane.version }
    }
}
