import Foundation
import Testing
import VMPaneCore

@testable import VMPaneQEMU

private let display = (width: 1280, height: 800)

private func steps(_ event: InputEvent, pressed: Int = 0) throws -> [QEMUInput.Step] {
    var pressed = pressed
    return try QEMUInput.steps(for: event, display: display, pressed: &pressed)
}

@Test func keysUseQKeyCodeNames() throws {
    #expect(
        try steps(.key(usage: 0x04, down: true)) == [
            .command("input-send-event", ["events": [["type": "key", "data": ["down": true, "key": ["type": "qcode", "data": "a"]]]]])
        ])
    #expect(KeyNames.name(forHIDUsage: 0xE3) == "meta_l")  // Windows key
    #expect(throws: QEMUInputError.unmappedKey(0x03)) { try steps(.key(usage: 0x03, down: true)) }
}

@Test func textIsTypedKeyByKeyWithShiftAndPauses() throws {
    let typed = try steps(.text("aA!\n"))
    let keys = typed.compactMap { step -> [String]? in
        guard case .command("send-key", let arguments) = step, case .array(let keys)? = arguments["keys"] else { return nil }
        return keys.compactMap { $0["data"]?.stringValue }
    }
    #expect(keys == [["a"], ["shift", "a"], ["shift", "1"], ["ret"]])
    #expect(typed.filter { $0 == .pause(QEMUInput.keyGap) }.count == 4)
    #expect(throws: QEMUInputError.unmappedCharacter("é")) { try steps(.text("é")) }
}

@Test func pointerScalesToTheTabletAxesAndTracksButtons() throws {
    var pressed = 0
    let press = try QEMUInput.steps(for: .pointer(x: 1279, y: 0, buttons: 1), display: display, pressed: &pressed)
    #expect(
        press == [
            .command(
                "input-send-event",
                [
                    "events": [
                        ["type": "abs", "data": ["axis": "x", "value": 32767]], ["type": "abs", "data": ["axis": "y", "value": 0]],
                        ["type": "btn", "data": ["button": "left", "down": true]],
                    ]
                ])
        ])
    #expect(pressed == 1)
    let release = try QEMUInput.steps(for: .pointer(x: 5000, y: -3, buttons: 2), display: display, pressed: &pressed)
    guard case .command(_, let arguments) = release.first, case .array(let events)? = arguments["events"] else {
        Issue.record("no events")
        return
    }
    #expect(events[0]["data"]?["value"] == 32767 && events[1]["data"]?["value"] == 0)  // clamped
    #expect(events.dropFirst(2).map { [$0["data"]?["button"], $0["data"]?["down"]] } == [["left", false], ["right", true]])
    #expect(pressed == 2)
}

@Test func scrollBecomesWheelNotches() throws {
    let scroll = try steps(.scroll(dx: 10, dy: -80))
    let buttons = scroll.compactMap { step -> String? in
        guard case .command(_, let arguments) = step, case .array(let events)? = arguments["events"] else { return nil }
        return events.first?["data"]?["button"]?.stringValue
    }
    #expect(buttons == ["wheel-up", "wheel-up", "wheel-right"])
}
