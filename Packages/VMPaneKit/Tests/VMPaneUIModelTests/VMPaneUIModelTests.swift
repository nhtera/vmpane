import Testing
@testable import VMPaneUI

@Test func windowTitleNamesTheVM() { #expect(UIInfo.windowTitle(vmName: "win11") == "win11 — VMPane") }
