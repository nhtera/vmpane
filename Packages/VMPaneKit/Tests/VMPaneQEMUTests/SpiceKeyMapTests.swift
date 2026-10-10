import Testing
import VMPaneCore

@testable import VMPaneQEMU

@Test func everyMacKeyHasAScancode() {
    for (usage, code) in KeyNames.macKeyCodes {
        #expect(SpiceKeyMap.scancode(forMacKeyCode: code) != nil, "no scancode for mac key \(code) (usage \(usage))")
    }
    let codes = Array(SpiceKeyMap.scancodes.values)
    #expect(Set(codes).count == codes.count)  // no two keys share a scancode
    #expect(codes.allSatisfy { (1..<512).contains($0) })  // CSInput tracks 512 key states
}

@Test func macKeysMapToPCScancodes() {
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 0) == 0x1E)  // A
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 55) == 0x15B)  // left Command → left Windows key (E0 5B)
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 58) == 0x38)  // left Option → Alt
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 61) == 0x138)  // right Option → AltGr (E0 38)
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 124) == 0x14D)  // right arrow
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 76) == 0x11C)  // keypad Enter
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 122) == 0x3B && SpiceKeyMap.scancode(forMacKeyCode: 111) == 0x58)  // F1, F12
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 10) == 0x56)  // ISO § → non-US backslash
    #expect(SpiceKeyMap.scancode(forMacKeyCode: 63) == nil)  // Fn
}
