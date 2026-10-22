import Foundation
import VMPaneControl
import VMPaneCore

/// The clipboard through the guest agent (macOS and Windows guests): the window's sharing (`ClipboardBridge`) and
/// the `vm.clipboard.read` / `vm.clipboard.write` methods. Linux guests share text through SPICE (spice-vdagent),
/// which these methods do not reach.
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
        let (execs, windows) = (agentExecs, peer.hello.os == "windows")
        let bridge =
            clipboardBridge
            ?? ClipboardBridge(
                pasteboard: hostPasteboard, mode: config.clipboard.mode, staging: HostFileSink.clipboardStaging(forVM: config.name),
                pull: { connection, paths, sink, prefix in
                    let guest = Guest(connection: connection, execs: execs, windows: windows)
                    return try await Self.pullTree(paths, into: sink, under: prefix, from: guest)
                },
                push: { [weak self] connection, paths in
                    guard let self else { return [] }
                    return try await self.stageClipboardFiles(paths, on: connection)
                })
        clipboardBridge = bridge
        let (mode, focused) = (config.clipboard.mode, windowFocused)
        let rich = config.clipboard.keepsFormatting && peer.hello.caps?.contains(AgentCap.clipboardRich) == true
        Task {
            await bridge.attach(connection)
            await bridge.setMode(mode)
            await bridge.setRich(rich)
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

    func clipboardRead(_ params: JSONValue?, from owner: ControlConnection? = nil) async -> Result<JSONValue, RPCError> {
        let types: [AgentClipboardType]
        switch RPCParams.decode(ReadParams.self, from: params ?? [:]) {
        case .success(let decoded): types = decoded.types ?? [.text, .png, .files]
        case .failure(let error): return .failure(error)
        }
        guard config.clipboard.mode == .off || config.clipboard.mode.receivesFromGuest else {
            return .failure(RPCError(.invalidState, "this VM's clipboard sharing is host to guest only"))
        }
        return await withClipboardAgent(.vmClipboardRead, from: owner) { connection, rich in
            // Formatted text only from an agent that has it (an older one refuses the request).
            let content = try await AgentClipboard.get(connection, types: rich ? types : types.filter { $0 != .html && $0 != .rtf })
            var items: [JSONValue] = []
            if let text = content.text { items.append(["type": "text", "text": .string(text)]) }
            if let html = content.html { items.append(["type": "html", "text": .string(html)]) }
            // RTF is 7-bit text; Latin-1 keeps any other byte as it is.
            if let rtf = content.rtf, let text = String(bytes: rtf, encoding: .utf8) ?? String(bytes: rtf, encoding: .isoLatin1) {
                items.append(["type": "rtf", "text": .string(text)])
            }
            if let png = content.png { items.append(["type": "png", "dataB64": .string(png.base64EncodedString())]) }
            if !content.files.isEmpty { items.append(["type": "files", "files": .array(content.files.map { .string($0) })]) }
            return ["items": .array(items)]
        }
    }

    func clipboardWrite(_ params: JSONValue?, from owner: ControlConnection? = nil) async -> Result<JSONValue, RPCError> {
        let items: [WriteItem]
        switch RPCParams.decode(WriteParams.self, from: params) {
        case .success(let decoded): items = decoded.items
        case .failure(let error): return .failure(error)
        }
        var content = ClipboardContent()
        for item in items {
            switch item.type {
            case .text: content.text = item.text
            case .html: content.html = item.text
            case .rtf: content.rtf = item.text.map { Data($0.utf8) }
            case .png:
                guard let data = item.dataB64.flatMap({ Data(base64Encoded: $0) }) else {
                    return .failure(RPCError(.invalidParams, "png items carry dataB64"))
                }
                content.png = data
            case .files: return .failure(RPCError(.invalidParams, "files go into the guest with vm.files.drop"))
            }
        }
        guard config.clipboard.mode == .off || config.clipboard.mode.sendsToGuest else {
            return .failure(RPCError(.invalidState, "this VM's clipboard sharing is guest to host only"))
        }
        return await withClipboardAgent(.vmClipboardWrite, from: owner) { connection, rich in
            guard rich || (content.html == nil && content.rtf == nil) else {
                throw RPCError(.invalidParams, "the guest's VMPane agent is older and takes plain text only (update its guest tools)")
            }
            try await AgentClipboard.set(connection, content)
            return [:]
        }
    }

    /// `body` with the guest's agent (and whether it has formatted text), once it has connected (a wait), unless
    /// `owner`'s request may not go on after it.
    private func withClipboardAgent(
        _ method: ControlMethod, from owner: ControlConnection?, _ body: (AgentConnection, Bool) async throws -> JSONValue
    ) async -> Result<JSONValue, RPCError> {
        guard config.clipboard.mode != .off else { return .failure(RPCError(.invalidState, "clipboard sharing is off for this VM")) }
        let admitted = agentGeneration
        guard let connection = await agentHub.waitForConnection(timeout: Self.agentWait),
            let caps = await agentHub.status.peer?.hello.caps, caps.contains(AgentCap.clipboard)
        else {
            return .failure(
                RPCError(.agentUnavailable, "the guest has no VMPane agent with clipboard support (macOS and Windows guests have one)"))
        }
        if let owner, let refusal = agentStopRefusal(since: admitted, identity(of: owner), method: method.rawValue) {
            return .failure(refusal)
        }
        do {
            return .success(try await body(connection, caps.contains(AgentCap.clipboardRich)))
        } catch let error as RPCError {
            return .failure(error)
        } catch let error as AgentConnection.ConnectionError {
            if case .rpc(let agentError) = error { return .failure(agentError) }
            return .failure(RPCError(.agentUnavailable, error.description))
        } catch {
            return .failure(RPCError(.internalError, ErrorText.readable(error)))
        }
    }
}
