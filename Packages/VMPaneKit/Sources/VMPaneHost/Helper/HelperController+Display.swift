import Foundation
import VMPaneControl
import VMPaneCore

/// Screenshot and input requests.
extension HelperController {
    private struct ScreenshotParams: Decodable {
        var maxEdge: Int?
    }

    private struct KeyParams: Decodable {
        var usage: UInt16
        var down: Bool
    }

    private struct TextParams: Decodable { var text: String }

    private struct PointerParams: Decodable {
        var x: Double
        var y: Double
        var buttons: Int?
    }

    private struct ScrollParams: Decodable {
        var dx: Double?
        var dy: Double?
    }

    func displayRequest(_ method: String, _ params: JSONValue?, from owner: ControlConnection? = nil) async -> Result<JSONValue, RPCError> {
        guard let backend else { return .failure(RPCError(.backendUnavailable, "no backend for this VM")) }
        let admitted = agentGeneration
        guard state == .running || state == .paused else {
            return .failure(RPCError(.invalidState, "the VM is \(state.rawValue)"))
        }
        inputsInFlight += 1
        defer { inputsInFlight -= 1 }
        do {
            switch ControlMethod(rawValue: method) {
            case .vmScreenshot?:
                return .success(try await screenshot(params, backend: backend))
            case .vmScreenRead?:
                return await screenRead(params)
            case .vmInputKey?:
                let key = try RPCParams.decode(KeyParams.self, from: params).get()
                try await backend.send(.key(usage: key.usage, down: key.down))
                await noteHeld(by: owner, since: admitted) {
                    _ = key.down ? $0.keys.insert(key.usage).memberAfterInsert : $0.keys.remove(key.usage)
                }
            case .vmInputText?:
                let text = try RPCParams.decode(TextParams.self, from: params).get().text
                if let owner {
                    try await type(text, backend: backend, admitted: admitted, caller: identity(of: owner))
                } else {
                    try await backend.send(.text(text))
                }
            case .vmInputPointer?:
                let pointer = try RPCParams.decode(PointerParams.self, from: params).get()
                try await backend.send(.pointer(x: pointer.x, y: pointer.y, buttons: pointer.buttons ?? 0))
                await noteHeld(by: owner, since: admitted) { held in
                    (held.buttons, held.x, held.y) = (pointer.buttons ?? 0, pointer.x, pointer.y)
                }
            case .vmInputScroll?:
                let scroll = try RPCParams.decode(ScrollParams.self, from: params).get()
                try await backend.send(.scroll(dx: scroll.dx ?? 0, dy: scroll.dy ?? 0))
            default:
                return .failure(RPCError(.methodNotFound, "unknown display method"))
            }
            return .success(.object([:]))
        } catch let error as RPCError {
            return .failure(error)
        } catch is Stopped {
            return .failure(inputStopError)
        } catch {
            return .failure(RPCError(.agentUnavailable, "display access failed: \(error)"))
        }
    }

    /// `vm.screenshot`: from the display source (encoded off the actor), else the backend's own capture.
    private func screenshot(_ params: JSONValue?, backend: VMBackend) async throws -> JSONValue {
        let maxEdge = try RPCParams.decode(ScreenshotParams.self, from: params).get().maxEdge ?? 1600
        let image = await captureImage()
        let encoded = await Blocking.run { image.flatMap { ScreenshotEncoder.screenshot($0, maxEdge: maxEdge) } }
        let shot: Screenshot
        if let encoded { shot = encoded } else { shot = try await backend.screenshot(maxEdge: maxEdge) }
        return [
            "dataB64": .string(shot.png.base64EncodedString()), "width": .int(Int64(shot.width)),
            "height": .int(Int64(shot.height)), "format": "png", "scale": .double(shot.scale),
        ]
    }
}
