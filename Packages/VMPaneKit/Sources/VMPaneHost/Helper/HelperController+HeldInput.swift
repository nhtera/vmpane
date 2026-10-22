import Foundation
import VMPaneControl
import VMPaneCore

/// Keys and mouse buttons an agent's single requests left down (`vm.input.key {down: true}`, `vm.input.pointer
/// {buttons}`). The helper lets them go itself when the person takes over, agents are stopped, or the agent leaves:
/// the agent's own release would be refused then, or never come, and the person would type with Shift held.
struct HeldInput: Sendable {
    var keys: Set<UInt16> = []
    var buttons = 0
    var x = 0.0
    var y = 0.0

    var isEmpty: Bool { keys.isEmpty && buttons == 0 }
}

extension HelperController {
    /// After an agent's key or pointer request went through: what it holds now. When the person took over, agents were
    /// stopped or the agent left while it was being sent (admitted at generation `admitted`), it is let go at once: the
    /// release those do may have run before this press arrived.
    func noteHeld(by owner: ControlConnection?, since admitted: Int, _ change: (inout HeldInput) -> Void) async {
        guard let owner else { return }
        let caller = identity(of: owner)
        guard caller.identity != .ui else { return }
        let key = ObjectIdentifier(owner)
        var held = heldInput[key] ?? HeldInput()
        change(&held)
        heldInput[key] = held.isEmpty ? nil : held
        if agentInputStopped(since: admitted, caller) { await releaseHeldInput(of: key) }
    }

    /// Lets go of what agents hold down: one connection's (it closed), or every agent's.
    func releaseHeldInput(of owner: ObjectIdentifier? = nil) async {
        let released = owner.map { key in heldInput[key].map { [$0] } ?? [] } ?? Array(heldInput.values)
        if let owner { heldInput[owner] = nil } else { heldInput.removeAll() }
        guard let backend, state == .running || state == .paused else { return }
        for held in released {
            for usage in held.keys { try? await backend.send(.key(usage: usage, down: false)) }
            if held.buttons != 0 { try? await backend.send(.pointer(x: held.x, y: held.y, buttons: 0)) }
        }
    }
}
