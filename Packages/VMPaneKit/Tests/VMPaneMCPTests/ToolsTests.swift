import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneMCP

@Test func keyCombosBecomeHIDUsages() {
    #expect(KeyCombo.usages("cmd+c") == [0xE3, 0x06])
    #expect(KeyCombo.usages("Ctrl+Alt+Delete") == [0xE0, 0xE2, 0x4C])
    #expect(KeyCombo.usages("enter") == [0x28])
    #expect(KeyCombo.usages("f12") == [0x45])
    #expect(KeyCombo.usages("shift+tab") == [0xE1, 0x2B])
    #expect(KeyCombo.usages("ctrl++") == [0xE0, 0x2E])
    #expect(KeyCombo.usages("hyper+x") == nil && KeyCombo.usages("cmd+nope") == nil)
}

@Test func exchangePathsStayInTheVMsFolder() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-x-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try GuestTools.exchangeFile(root, vm: "Ubuntu", "a/b.txt")
    #expect(file.path == root.appendingPathComponent("Ubuntu/a/b.txt").path)
    for bad in ["../x", "/etc/passwd", "a/../../x", ""] {
        #expect(throws: ToolFailure.self) { try GuestTools.exchangeFile(root, vm: "Ubuntu", bad) }
    }
    #expect(throws: ToolFailure.self) { try GuestTools.exchangeFile(root, vm: "../evil", "x") }
}

@Test func aCallTheHelperNeverAnsweredIsReadable() {
    // The kill switch closes an agent's connection; a transfer cut that way is a result, not a protocol error.
    #expect(VMAccess.explain(ControlClientError.connectionClosed, vm: "Ubuntu").contains("kill switch"))
    #expect(VMAccess.explain(ControlClientError.timedOut(method: "agent.file.pull"), vm: "Ubuntu").hasPrefix("Ubuntu did not answer"))
}

@Test func toolActionsBecomeTheHelpersInGuestPixels() throws {
    let click = try InputTools.helperAction("click", ["x": 10, "y": 20, "count": 2, "modifiers": ["shift", "cmd"]], scale: 2)
    #expect(click == ["type": "click", "x": 20.0, "y": 40.0, "button": "left", "count": 2, "modifiers": [0xE1, 0xE3]])
    #expect(try InputTools.helperAction("key", ["combo": "ctrl+c"], scale: 2) == ["type": "key", "usages": [0xE0, 0x06]])
    #expect(
        try InputTools.helperAction("type", ["text": "hi", "submit": true], scale: 2) == ["type": "text", "text": "hi", "submit": true])
    let scroll = try InputTools.helperAction("scroll", ["dy": 120], scale: 2)
    #expect(scroll == ["type": "scroll", "dx": 0.0, "dy": -120.0], "down is negative there")
    let drag = try InputTools.helperAction("drag", ["from": ["x": 1, "y": 2], "to": ["x": 3, "y": 4]], scale: 1.5)
    #expect(drag["to"] == ["x": 4.5, "y": 6.0])
    #expect(throws: ToolFailure.self) { try InputTools.helperAction("click", ["x": 1], scale: 1) }
    #expect(throws: ToolFailure.self) { try InputTools.helperAction("click", ["x": 1, "y": 1, "modifiers": ["hyper"]], scale: 1) }
    #expect(throws: ToolFailure.self) { try InputTools.helperAction("key", ["combo": "ctrl+nokey"], scale: 1) }
    #expect(throws: ToolFailure.self) { try InputTools.helperAction("fly", [:], scale: 1) }
}

@Test func verificationIsReportedInScreenshotPixels() {
    let verified = InputTools.screenshotSpace(
        ["status": "changed", "changeRatio": 0.125, "bbox": ["x": 300, "y": 150, "width": 600, "height": 30], "settled": true], scale: 3)
    #expect(verified["bbox"] == ["x": 100, "y": 50, "width": 200, "height": 10])
    #expect(InputTools.describe(verified) == "the screen changed (12.5% around 100,50 200×10)")
    #expect(InputTools.describe(["status": "unchanged"]) == "no visible change")
    #expect(InputTools.describe(["status": "changed", "changeRatio": 0.001, "tiles": 1]).hasPrefix("a cursor-sized change"))
    #expect(InputTools.describe(["status": "unknown", "reason": "helper_outdated"]).contains("helper_outdated"))
}

@Test func anOlderHelperIsRecognizedByItsRefusal() {
    #expect(InputTools.isOutdatedHelper(ToolFailure("x", code: ControlErrorCode.methodNotFound.rawValue)))
    #expect(InputTools.isOutdatedHelper(ToolFailure("Refused by w: vm.input.batch is not an allowed method. Its owner…")))
    #expect(!InputTools.isOutdatedHelper(ToolFailure("Refused by w: vm.input.batch needs policy level control; this VM allows observe")))
}

@Test func batchTimeoutsCoverTypingAtQEMUsPace() {
    let actions: [JSONValue] = [["type": "text", "text": .string(String(repeating: "a", count: 3000))], ["type": "wait", "ms": 5000]]
    let timeout = InputTools.timeout(actions, settleMs: 300)
    #expect(timeout >= .seconds(390 + 5))
}
