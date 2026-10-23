import Testing

@testable import VMPaneUI

@Test func windowTitleNamesTheVM() { #expect(UIInfo.windowTitle(vmName: "win11") == "win11 — VMPane") }

/// Each setting the sheet edits belongs to the section that shows it (the sidebar marks pending and refused changes).
@Test func everySettingHasItsSection() {
    let expected: [String: SettingsSection] = [
        "name": .general, "cpu.count": .hardware, "memory.mib": .hardware, "display.widthPx": .display,
        "display.autoResize": .display, "display.scaling": .display, "clipboard.mode": .sharing,
        "clipboard.keepFormatting": .sharing, "audio.output": .sharing, "audio.input": .sharing, "shares": .sharing,
        "shares.0.readOnly": .sharing, "mcp.policy": .agents, "mcp.signIn": .agents, "clipboard.allowWithAgents": .agents,
        "network.0.mode": .network, "portForwards": .portForwarding,
    ]
    for (path, section) in expected { #expect(SettingsSection.holding(path) == section, "\(path)") }
    #expect(SettingsSection.holding("named") == nil, "a prefix is a whole key")
}
