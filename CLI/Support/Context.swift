import ArgumentParser
import Foundation
import VMPaneControl
import VMPaneCore

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of text.") var json = false
}

/// What every command shares: the library, the helper connector, and how failures become exit codes.
enum CLI {
    static let paths = VMPanePaths.standard()
    static let library = VMLibrary(paths: paths)

    /// This process's policy identity: `operator` for a person at a terminal who granted it (`vmpane operator
    /// grant`), else policy-bound like an agent.
    static let identity: ClientIdentity =
        InteractiveSession.isInteractive() && OperatorGrant.isGranted(paths: paths) ? .operator : .automated

    static var ops: LibraryOps {
        LibraryOps(library: library, identity: identity).recordingInVMLogs(label: identity == .operator ? "operator" : "cli", kind: "cli")
    }

    static let connector = HelperConnector(
        paths: paths, clientName: "vmpane", clientVersion: VMPane.version, kind: "cli", operatorClaim: identity == .operator,
        launch: launchHelper)

    /// Starts a VM's helper headless from the VMPane.app this vmpane lives in.
    @Sendable static func launchHelper(_ bundle: VMBundle) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard let app = LaunchCoordinator.enclosingApp(of: Bundle.main.executableURL ?? executable) else {
            throw RPCError(.backendUnavailable, "this vmpane is not inside VMPane.app, so it cannot start VMs")
        }
        try LaunchCoordinator.launch(bundle, app: app, appVersion: VMPane.version, paths: paths, headless: true)
    }

    static func item(_ selector: String) throws -> VMLibrary.Item {
        try VMSelector.resolve(selector, in: try ops.list())
    }

    /// The VM's state from its helper, or "stopped" without one.
    static func state(_ item: VMLibrary.Item) async -> String {
        if item.error != nil { return "unreadable" }
        guard let session = try? await connector.connect(item.id) else { return "stopped" }
        defer { session.client.close() }
        return (try? await session.client.call(ControlMethod.vmInfo.rawValue, timeout: .seconds(5)))?["state"]?.stringValue ?? "unknown"
    }

    /// A session with the VM's running helper; fails (75) when the VM is not running.
    static func running(_ item: VMLibrary.Item) async throws -> HelperDiscovery.Session {
        do {
            return try await connector.connect(item.id)
        } catch HelperDiscovery.DiscoveryError.notRunning {
            throw RPCError(.invalidState, "\(item.config?.name ?? "the VM") is not running")
        }
    }

    static func print(_ value: JSONValue, json: Bool, text: () -> String) {
        Swift.print(json ? OutputFormatter.json(value) : text())
    }

    /// Runs a command body; failures print "vmpane: …" on stderr and exit with their status.
    static func guarded(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as ArgumentParser.ExitCode {
            throw error
        } catch let error as RPCError {
            fail(error.message, ExitStatus.of(error))
        } catch let error as VMSelector.Failure {
            fail(error.description, .notFound)
        } catch let error as LibraryOps.PolicyDenied {
            fail(error.reason, .policyDenied)
        } catch is LibraryOps.VMRunning {
            fail("the VM is running: stop it first", .tempFail)
        } catch {
            fail(String(describing: error), .failure)
        }
    }

    static func fail(_ message: String, _ status: ExitStatus) -> Never {
        FileHandle.standardError.write(Data("vmpane: \(message)\n".utf8))
        Foundation.exit(status.rawValue)
    }
}
