import CoreGraphics
import Foundation
import VMPaneControl
import VMPaneCore

/// `vm.screen.read`: what is on the VM's screen as text with boxes (guest pixels). `ocr` recognizes it on the Mac
/// from the display (any guest, no guest software); `elements` asks the guest tools for the controls (`screen` cap:
/// UI Automation on Windows, the accessibility tree on macOS); `auto` is elements when the guest tools can, else ocr;
/// `both` returns the two lists. All text comes from the VM: it is cleaned (`GuestText`) and never logged.
extension HelperController {
    static let screenReadMaxItems = 800

    private struct Region: Decodable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    private struct ScreenReadParams: Decodable {
        var source: String?
        var region: Region?
        var maxItems: Int?
    }

    func screenRead(_ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        guard state == .running || state == .paused else { return .failure(RPCError(.invalidState, "the VM is \(state.rawValue)")) }
        let request: ScreenReadParams
        switch RPCParams.decode(ScreenReadParams.self, from: params) {
        case .success(let decoded): request = decoded
        case .failure(let error): return .failure(error)
        }
        let source = request.source ?? "auto"
        guard ["ocr", "elements", "auto", "both"].contains(source) else {
            return .failure(RPCError(.invalidParams, "source is ocr, elements, auto or both"))
        }
        let maxItems = min(max(request.maxItems ?? 300, 1), Self.screenReadMaxItems)
        let region = request.region.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let canListControls = await agentHub.status.peer?.hello.caps?.contains(AgentCap.screen) == true
        guard let image = await captureImage() else {
            return .failure(RPCError(.backendUnavailable, "the VM's display cannot be read now"))
        }
        let screen = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var reply: [String: JSONValue] = [:]
        var controls: Result<JSONValue, RPCError>?
        if source == "elements" || source == "both" || (source == "auto" && canListControls) {
            controls =
                canListControls ? await self.controls(maxItems: maxItems, region: region, screen: screen) : .failure(Self.noControls)
        }
        if source == "elements", case .failure(let error)? = controls { return .failure(error) }
        switch controls {
        case .success(let list)?: reply["elements"] = list
        // Why there are none, for auto and both (which read the text instead or as well).
        case .failure(let error)?: reply["elementsError"] = .string(error.message)
        case nil: break
        }
        // auto reads the text when the controls cannot be had or there are none (an app that exposes nothing).
        let useOCR = source == "ocr" || source == "both" || (source == "auto" && (reply["elements"]?["items"]?.isEmptyArray ?? true))
        reply["source"] = .string(source == "auto" ? (useOCR ? "ocr" : "elements") : source)
        reply["screen"] = ["width": .int(Int64(image.width)), "height": .int(Int64(image.height))]
        if useOCR {
            do {
                reply["ocr"] = try await recognizedText(image, region: region, maxItems: maxItems)
            } catch {
                return .failure(RPCError(.internalError, "text recognition failed: \(error.localizedDescription)"))
            }
        }
        if source == "auto", useOCR { reply["elements"] = nil }
        return .success(.object(reply))
    }

    /// The guest tools' refusal in VMPane's words: a code from a known set and a text that is the host's, the guest's
    /// own message only quoted and cleaned (it is the guest's, and must not pass for VMPane's).
    static func controlsRefusal(_ error: RPCError, os: GuestOS) -> RPCError {
        switch AgentErrorCode(rawValue: error.code) {
        case .permissionDenied? where os == .macos:
            RPCError(
                .agentUnavailable,
                "Accessibility is not allowed for VMPane Agent in the VM yet: in the VM, allow vmpane-agent in System Settings "
                    + "› Privacy & Security › Accessibility (the screen's text can be read with ocr meanwhile)")
        case .noSession?: RPCError(.agentUnavailable, "nobody is signed in to the VM: its controls are read in the user's session")
        case .busy?: RPCError(.busy, "the VM's controls are being read already")
        case .timeout?: RPCError(.agentUnavailable, "the app in front of the VM did not answer in time")
        default:
            RPCError(
                .agentUnavailable,
                "the guest tools could not list the VM's controls: \(GuestText.clean(error.message).debugDescription)")
        }
    }

    static let noControls = RPCError(
        .agentUnavailable,
        "this VM's guest tools cannot list its controls (none are running, or they are older: update them; Windows and macOS "
            + "guests), read it with ocr")

    /// At most this much text in one read, all items together: what comes back is read by a model.
    static let screenReadMaxCharacters = 40_000

    /// The recognized lines (`ScreenText`), cleaned and capped.
    private func recognizedText(_ image: CGImage, region: CGRect?, maxItems: Int) async throws -> JSONValue {
        let started = ContinuousClock.now
        let lines = try await Blocking.run { try ScreenText.recognize(image, region: region) }
        let took = "\(ContinuousClock.now - started)", size = "\(image.width)x\(image.height)"
        // Counts only: the text is the guest's.
        Self.log.info("screen read: ocr \(lines.count) lines of \(size, privacy: .public) in \(took, privacy: .public)")
        return Self.capped(
            lines.map { ["text": .string(GuestText.clean($0.text, maxLength: 400)), "rect": Self.rect($0.rect)] }, maxItems: maxItems)
    }

    /// The guest tools' controls of the foreground window (`screen.elements`), within `region`, cleaned and capped.
    private func controls(maxItems: Int, region: CGRect?, screen: CGRect) async -> Result<JSONValue, RPCError> {
        guard let connection = await agentHub.connection else { return .failure(Self.noControls) }
        do {
            let reply = try await connection.call(AgentMethod.screenElements, ["maxElements": .int(Int64(Self.screenReadMaxItems))])
            // Boxes in another space (macOS: the display's points) are scaled to the display's pixels.
            let space = (reply.result["space"]?.arrayItems ?? []).compactMap(\.intValue).map(Double.init)
            let (scaleX, scaleY) =
                space.count == 2 && space[0] > 0 && space[1] > 0 ? (screen.width / space[0], screen.height / space[1]) : (1, 1)
            var items: [JSONValue] = []
            for element in reply.result["elements"]?.arrayItems ?? [] {
                let box = (element["rect"]?.arrayItems ?? []).compactMap(\.intValue).map(Double.init)
                guard box.count == 4, box[2] > 0, box[3] > 0 else { continue }
                // Only what is on the screen (what a screenshot shows), whatever the guest tools said.
                let rect = CGRect(x: box[0] * scaleX, y: box[1] * scaleY, width: box[2] * scaleX, height: box[3] * scaleY)
                    .intersection(screen)
                guard !rect.isEmpty else { continue }
                if let region, !rect.intersects(region) { continue }
                // The role is a word from a list the agent knows; anything else is not passed on as it came.
                let role = element["role"]?.stringValue ?? ""
                let known = !role.isEmpty && role.count <= 20 && role.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
                var item: [String: JSONValue] = [
                    "role": .string(known ? role : "other"),
                    "name": .string(GuestText.clean(element["name"]?.stringValue ?? "")), "rect": Self.rect(rect),
                    "enabled": .bool(element["enabled"] != false), "focused": .bool(element["focused"] == true),
                ]
                if let value = element["value"]?.stringValue { item["value"] = .string(GuestText.clean(value)) }
                items.append(.object(item))
            }
            let capped = Self.capped(items, maxItems: maxItems)
            return .success(reply.result["truncated"] == true ? capped.setting("truncated", true) : capped)
        } catch let error as AgentConnection.ConnectionError {
            if case .rpc(let agentError) = error {
                if agentError.code == AgentErrorCode.permissionDenied.rawValue, config.os == .macos {
                    // The person at the VM window can give the grant: tell it (it shows that once).
                    server?.broadcast(topic: "agent", method: ControlNotification.screenAccessibilityNeeded.rawValue, params: [:])
                }
                return .failure(Self.controlsRefusal(agentError, os: config.os))
            }
            return .failure(RPCError(.agentUnavailable, error.description))
        } catch {
            return .failure(RPCError(.internalError, ErrorText.readable(error)))
        }
    }

    /// `items` cut to `maxItems` and `screenReadMaxCharacters` of text, with whether anything was cut.
    static func capped(_ items: [JSONValue], maxItems: Int) -> JSONValue {
        var kept: [JSONValue] = []
        var characters = 0
        for item in items.prefix(maxItems) {
            characters += (item["text"] ?? item["name"])?.stringValue?.count ?? 0
            characters += item["value"]?.stringValue?.count ?? 0
            guard characters <= screenReadMaxCharacters else { break }
            kept.append(item)
        }
        return ["items": .array(kept), "truncated": .bool(kept.count < items.count)]
    }

    static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .int(Int64($0.rounded())) })
    }
}

extension JSONValue {
    fileprivate var arrayItems: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }

    fileprivate var isEmptyArray: Bool? {
        guard case .array(let items) = self else { return nil }
        return items.isEmpty
    }

    fileprivate func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }
}
