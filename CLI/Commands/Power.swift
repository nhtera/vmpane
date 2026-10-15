import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

/// A lifecycle request to the VM's helper, printing the state it answers.
private func lifecycle(_ selector: String, _ method: ControlMethod, params: JSONValue? = nil, launching: Bool = false, json: Bool)
    async throws
{
    let item = try CLI.item(selector)
    let session = launching ? try await CLI.connector.connectLaunching(item) : try await CLI.running(item)
    defer { session.client.close() }
    let result = try await session.client.call(method.rawValue, params: params, timeout: .seconds(180))
    CLI.print(result, json: json) {
        let state = result["state"]?.stringValue ?? "?"
        return [state, result["message"]?.stringValue].compactMap { $0 }.joined(separator: ": ")
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a VM (its window shows unless --headless).")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Flag(help: "Run without a window.") var headless = false
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            warnIfLowOnMemory(try CLI.item(vm))
            try await lifecycle(vm, .vmStart, params: ["headless": .bool(headless)], launching: true, json: output.json)
        }
    }

    /// Says so (on stderr) when the Mac has less memory available than the VM may use; it still starts.
    private func warnIfLowOnMemory(_ item: VMLibrary.Item) {
        guard let config = item.config, let host = HostMemory.current() else { return }
        let guestBytes = UInt64(max(0, config.memory.mib)) << 20
        guard host.tooLow(forGuest: guestBytes) else { return }
        let warning =
            "vmpane: warning: \(config.name) can use \(HostMemory.describe(guestBytes)) of memory, but only "
            + "\(HostMemory.describe(host.availableBytes)) is available on this Mac: it may run slowly or crash.\n"
        FileHandle.standardError.write(Data(warning.utf8))
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shut a VM down (the guest's power button), or turn it off with --force.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Flag(help: "Turn it off at once, like pulling the plug.") var force = false
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded {
            try await lifecycle(vm, .vmStop, params: ["mode": force ? "force" : "graceful"], json: output.json)
        }
    }
}

struct Suspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a VM's memory to disk and stop it; it resumes at the next start.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded { try await lifecycle(vm, .vmSuspend, json: output.json) }
    }
}

struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause a running VM.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded { try await lifecycle(vm, .vmPause, json: output.json) }
    }
}

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume a paused VM.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await CLI.guarded { try await lifecycle(vm, .vmResume, json: output.json) }
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a PNG of a running VM's screen.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Option(name: .shortAndLong, help: "Where to save the PNG.") var output: String
    @Option(help: "Longest edge in pixels (0: full size).") var maxEdge = 0

    func run() async throws {
        try await CLI.guarded {
            let item = try CLI.item(vm)
            let session = try await CLI.running(item)
            defer { session.client.close() }
            let shot = try await session.client.call(ControlMethod.vmScreenshot.rawValue, params: ["maxEdge": .int(Int64(maxEdge))])
            guard let png = shot["dataB64"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
                throw RPCError(.internalError, "the helper sent no image")
            }
            try png.write(to: URL(fileURLWithPath: output))
        }
    }
}
