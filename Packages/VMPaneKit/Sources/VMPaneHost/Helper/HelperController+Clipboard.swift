import Foundation
import VMPaneControl
import VMPaneCore

/// The clipboard through the guest agent (macOS guests): the window's sharing (`ClipboardBridge`) and the
/// `vm.clipboard.read` / `vm.clipboard.write` methods. Linux and Windows guests share text through SPICE
/// (spice-vdagent), which these methods do not reach.
extension HelperController {
    /// Gives the helper the Mac's pasteboard (the helper app's `NSPasteboard`); without it nothing is shared.
    public func setHostPasteboard(_ pasteboard: HostPasteboard) { hostPasteboard = pasteboard }

    /// The VM window became or stopped being the key window.
    public func windowFocusChanged(_ focused: Bool) async {
        windowFocused = focused
        await clipboardBridge?.setFocused(focused)
    }

    /// The bridge goes with the VM: the next start makes a fresh one with that start's settings.
    func clipboardFollowState(_ next: VMRunState) {
        guard next == .stopped || next == .error, let bridge = clipboardBridge else { return }
        clipboardBridge = nil
        Task { await bridge.stop() }
    }

    /// The bridge for an agent that serves the clipboard, attached to `connection` (made on first use).
    func clipboardAttach(_ connection: AgentConnection, peer: AgentConnection.Peer) -> ClipboardBridge? {
        guard let hostPasteboard, peer.hello.caps?.contains(AgentCap.clipboard) == true, config.clipboard.mode != .off else { return nil }
        let bridge =
            clipboardBridge
            ?? ClipboardBridge(
                pasteboard: hostPasteboard, mode: config.clipboard.mode, downloads: HostFileSink.downloads(forVM: config.name)
            ) { connection, path, handle, sink in
                try await Self.pull(path, into: handle, sink: sink, on: connection)
            }
        clipboardBridge = bridge
        let (mode, focused) = (config.clipboard.mode, windowFocused)
        Task {
            await bridge.attach(connection)
            await bridge.setMode(mode)
            await bridge.setFocused(focused)
        }
        return bridge
    }

    private struct ReadParams: Decodable { var types: [AgentClipboardType]? }

    private struct WriteItem: Decodable {
        var type: AgentClipboardType
        var text: String?
        var dataB64: String?
    }

    private struct WriteParams: Decodable { var items: [WriteItem] }

    func clipboardRead(_ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        let types: [AgentClipboardType]
        switch RPCParams.decode(ReadParams.self, from: params ?? [:]) {
        case .success(let decoded): types = decoded.types ?? [.text, .png, .files]
        case .failure(let error): return .failure(error)
        }
        return await withClipboardAgent { connection in
            let content = try await AgentClipboard.get(connection, types: types)
            var items: [JSONValue] = []
            if let text = content.text { items.append(["type": "text", "text": .string(text)]) }
            if let png = content.png { items.append(["type": "png", "dataB64": .string(png.base64EncodedString())]) }
            if !content.files.isEmpty { items.append(["type": "files", "files": .array(content.files.map { .string($0) })]) }
            return ["items": .array(items)]
        }
    }

    func clipboardWrite(_ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        let items: [WriteItem]
        switch RPCParams.decode(WriteParams.self, from: params) {
        case .success(let decoded): items = decoded.items
        case .failure(let error): return .failure(error)
        }
        var content = ClipboardContent()
        for item in items {
            switch item.type {
            case .text: content.text = item.text
            case .png:
                guard let data = item.dataB64.flatMap({ Data(base64Encoded: $0) }) else {
                    return .failure(RPCError(.invalidParams, "png items carry dataB64"))
                }
                content.png = data
            case .files: return .failure(RPCError(.invalidParams, "files go into the guest with vm.files.drop"))
            }
        }
        return await withClipboardAgent { connection in
            try await AgentClipboard.set(connection, content)
            return [:]
        }
    }

    private func withClipboardAgent(_ body: (AgentConnection) async throws -> JSONValue) async -> Result<JSONValue, RPCError> {
        guard config.clipboard.mode != .off else { return .failure(RPCError(.invalidState, "clipboard sharing is off for this VM")) }
        guard let connection = await agentHub.waitForConnection(timeout: Self.agentWait),
            await agentHub.status.peer?.hello.caps?.contains(AgentCap.clipboard) == true
        else {
            return .failure(RPCError(.agentUnavailable, "the guest has no VMPane agent with clipboard support (macOS guests have one)"))
        }
        do {
            return .success(try await body(connection))
        } catch let error as RPCError {
            return .failure(error)
        } catch let error as AgentConnection.ConnectionError {
            if case .rpc(let agentError) = error { return .failure(agentError) }
            return .failure(RPCError(.agentUnavailable, error.description))
        } catch {
            return .failure(RPCError(.internalError, String(describing: error)))
        }
    }
}
