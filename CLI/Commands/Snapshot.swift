import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Take, list, restore and delete a VM's snapshots.",
        subcommands: [SnapshotList.self, SnapshotCreate.self, SnapshotRestore.self, SnapshotDelete.self])
}

/// The VM's snapshots, through its helper (started headless for a stopped VM).
private func snapshots(_ session: HelperDiscovery.Session) async throws -> [JSONValue] {
    guard case .array(let list) = try await session.client.call(ControlMethod.vmSnapshotList.rawValue) else { return [] }
    return list
}

/// The snapshot named or identified by `selector` (its id, or a unique name).
private func snapshotID(_ selector: String, in list: [JSONValue]) throws -> String {
    if let match = list.first(where: { $0["id"]?.stringValue == selector }) { return match["id"]?.stringValue ?? selector }
    let named = list.filter { $0["name"]?.stringValue == selector }
    guard named.count == 1, let id = named[0]["id"]?.stringValue else {
        throw RPCError(
            .invalidParams,
            named.isEmpty
                ? "no snapshot \(selector.debugDescription)" : "several snapshots are named \(selector.debugDescription): use the id")
    }
    return id
}

struct SnapshotList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List a VM's snapshots.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            let session = try await CLI.connector.connectLaunching(try CLI.item(vm))
            defer { session.client.close() }
            let list = try await snapshots(session)
            CLI.print(.array(list), json: output.json) {
                OutputFormatter.table(
                    ["NAME", "ID", "KIND", "TAKEN"],
                    list.map { snapshot in ["name", "id", "kind", "createdAt"].map { snapshot[$0]?.stringValue ?? "" } })
            }
        }
    }
}

struct SnapshotCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Take a snapshot (live, with memory, of a running VM; of the disks of a stopped one).")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Argument(help: "The snapshot's name.") var name: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            let session = try await CLI.connector.connectLaunching(try CLI.item(vm))
            defer { session.client.close() }
            let state = try await session.client.call(ControlMethod.vmInfo.rawValue)["state"]?.stringValue
            let kind = state == "running" || state == "paused" ? "live" : "disk"
            let meta = try await session.client.call(
                ControlMethod.vmSnapshotCreate.rawValue, params: ["name": .string(name), "kind": .string(kind)], timeout: .seconds(600))
            CLI.print(meta, json: output.json) { meta["id"]?.stringValue ?? "" }
        }
    }
}

struct SnapshotRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Go back to a snapshot (a running VM is turned off first; what changed since is lost).")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Argument(help: "The snapshot: its id or name.") var snapshot: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            let session = try await CLI.connector.connectLaunching(try CLI.item(vm))
            defer { session.client.close() }
            let id = try snapshotID(snapshot, in: try await snapshots(session))
            let result = try await session.client.call(
                ControlMethod.vmSnapshotRestore.rawValue, params: ["id": .string(id)], timeout: .seconds(600))
            CLI.print(result, json: output.json) { result["state"]?.stringValue ?? "" }
        }
    }
}

struct SnapshotDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a snapshot.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Argument(help: "The snapshot: its id or name.") var snapshot: String

    func run() async throws {
        try await CLI.guarded {
            let session = try await CLI.connector.connectLaunching(try CLI.item(vm))
            defer { session.client.close() }
            let id = try snapshotID(snapshot, in: try await snapshots(session))
            _ = try await session.client.call(ControlMethod.vmSnapshotDelete.rawValue, params: ["id": .string(id)], timeout: .seconds(120))
        }
    }
}
