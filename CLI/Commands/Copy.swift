import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

/// `vmpane cp`: files between the Mac and a running VM through its guest agent; the VM side is `vm:path`.
struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp", abstract: "Copy a file to or from a running VM: vmpane cp file.txt ubuntu:/tmp/ or vmpane cp ubuntu:/etc/hosts ."
    )
    @Argument(help: "From: a Mac path, or VM:path.") var source: String
    @Argument(help: "To: a Mac path, or VM:path (a path ending in / is a folder).") var destination: String
    @Flag(help: "Replace an existing file.") var overwrite = false

    func run() async throws {
        try await CLI.guarded {
            switch (Self.vmSide(source), Self.vmSide(destination)) {
            case (nil, let (vm, guest)?):
                let host = URL(fileURLWithPath: source).standardizedFileURL
                let target = guest.hasSuffix("/") ? guest + host.lastPathComponent : guest
                try await transfer(vm, .agentFilePush, ["hostPath": .string(host.path), "guestPath": .string(target)])
            case (let (vm, guest)?, nil):
                var host = URL(fileURLWithPath: destination).standardizedFileURL
                var isFolder: ObjCBool = false
                if destination.hasSuffix("/")
                    || (FileManager.default.fileExists(atPath: host.path, isDirectory: &isFolder) && isFolder.boolValue)
                {
                    host.appendPathComponent((guest as NSString).lastPathComponent)
                }
                try await transfer(vm, .agentFilePull, ["guestPath": .string(guest), "hostPath": .string(host.path)])
            default:
                throw RPCError(.invalidParams, "one side is VM:path and the other a Mac path")
            }
        }
    }

    private func transfer(_ vm: String, _ method: ControlMethod, _ params: [String: JSONValue]) async throws {
        let session = try await CLI.running(try CLI.item(vm))
        defer { session.client.close() }
        var params = params
        params["overwrite"] = .bool(overwrite)
        let result = try await session.client.call(method.rawValue, params: .object(params), timeout: .seconds(3600))
        print("\(result["bytes"]?.intValue ?? 0) bytes")
    }

    /// `vm:path` → (vm, path); a Mac path (absolute, relative, or with a "/" before the ":") → nil.
    static func vmSide(_ argument: String) -> (String, String)? {
        guard let colon = argument.firstIndex(of: ":"), colon != argument.startIndex,
            !argument[..<colon].contains("/"), argument[argument.index(after: colon)...].hasPrefix("/")
        else { return nil }
        return (String(argument[..<colon]), String(argument[argument.index(after: colon)...]))
    }
}

/// `vmpane ssh`: ssh into a VM through its forward to guest port 22.
struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "ssh into a VM through its port forward to port 22.")
    @Argument(help: "The VM: its name, id or short id.") var vm: String
    @Option(name: .shortAndLong, help: "The guest user.") var user: String?
    @Argument(parsing: .postTerminator, help: "More ssh arguments, after --.") var arguments: [String] = []

    func run() async throws {
        try await CLI.guarded {
            let item = try CLI.item(vm)
            let session = try await CLI.running(item)
            let listed = try await session.client.call(ControlMethod.vmPortsList.rawValue)
            session.client.close()
            guard case .array(let rules)? = listed["rules"],
                let rule = rules.first(where: { $0["guestPort"]?.intValue == 22 && $0["proto"] == "tcp" && $0["status"] == "listening" }),
                let port = rule["hostPort"]?.intValue
            else {
                throw RPCError(.invalidState, "no forward to the VM's port 22: vmpane port add \(vm) 2222:22")
            }
            let host = rule["hostAddress"] == "::1" ? "::1" : "127.0.0.1"
            let target = user.map { "\($0)@\(host)" } ?? host
            let argv = ["/usr/bin/ssh", "-p", String(port), "-o", "HostKeyAlias=vmpane-\(ShortID(item.id))", target] + arguments
            let cArgs = argv.map { strdup($0) } + [nil]
            execv(argv[0], cArgs)
            throw RPCError(.internalError, "cannot run ssh: \(String(cString: strerror(errno)))")
        }
    }
}
