import Foundation
import VMPaneControl
import VMPaneCore

/// Files dragged out of a Windows VM's window into Finder: while the person drags out of the window, the guest is
/// asked what its drag carries (`drag.probe`), and the drag goes on as one of file promises on the Mac; each is
/// copied from the guest into the folder Finder names when it is dropped (`HostFileSink`: sanitized names, no
/// links followed, quarantine, a budget per item).
extension HelperController {
    /// Items one drag carries at most (the guest names them).
    static let maxDragItems = 100

    /// What the guest's drag carries now; none without an agent that can tell, or without a drag of files. The
    /// drag's copies share one budget (`HostFileSink`'s caps).
    public func dragOutProbe() async -> [AgentDragProbeResult.Item] {
        guard let connection = await agentHub.connection, await agentHub.status.peer?.hello.caps?.contains(AgentCap.drag) == true
        else { return [] }
        do {
            let call = try await connection.call(AgentMethod.dragProbe, [:], timeout: .seconds(3))
            dragOutBudget = HostFileSink.Budget()
            return Array(try RPCParams.decode(AgentDragProbeResult.self, from: call.result).get().items.prefix(Self.maxDragItems))
        } catch {
            Self.log.notice("the guest's drag could not be read: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Copies guest file or folder `path` to host `destination` (what Finder asked the promise for: its folder and
    /// name); returns where it is (another name only when that one is taken).
    public func dragOutCopy(_ path: String, to destination: URL) async throws -> URL {
        guard let connection = await agentHub.connection, let peer = await agentHub.status.peer, let budget = dragOutBudget else {
            throw RPCError(.agentUnavailable, "the guest agent is not connected")
        }
        let guest = Guest(connection: connection, execs: agentExecs, windows: peer.hello.os == "windows")
        let sink = HostFileSink(root: destination.deletingLastPathComponent(), budget: budget)
        let landed = try await Self.pullTree([path], into: sink, under: "", from: guest, named: destination.lastPathComponent)
        guard let url = landed.first else { throw RPCError(.invalidParams, "\(path) is not a file or folder in the guest") }
        return url
    }
}
