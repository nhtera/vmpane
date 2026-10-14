import Foundation
import Testing
import VMPaneControl

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
