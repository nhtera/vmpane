import Foundation
import Testing

@testable import VMPaneCore

@Test func mergePatchFollowsRFC7386() {
    let base: JSONValue = ["a": 1, "b": ["c": 2, "d": 3], "e": [1, 2]]
    let patch: JSONValue = ["b": ["c": 5, "d": nil], "e": [9], "f": "new"]
    #expect(SettingsPatch.merge(base, patch) == ["a": 1, "b": ["c": 5], "e": [9], "f": "new"])
}

@Test func changedPathsAreLeavesIndexedArraysAndWholeLists() {
    let old: JSONValue = [
        "cpu": ["count": 2], "network": [["mode": "nat", "macAddress": "x"]],
        "shares": [["name": "a"]], "name": "L",
    ]
    let new: JSONValue = [
        "cpu": ["count": 4], "network": [["mode": "none", "macAddress": "x"]],
        "shares": [["name": "a"], ["name": "b"]], "name": "L",
    ]
    #expect(SettingsPatch.changedPaths(old, new) == ["cpu.count", "network.0.mode", "shares"])
    // A NIC added or removed changes the list as a whole.
    let more: JSONValue = ["network": [["mode": "nat"], ["mode": "nat"]]]
    #expect(SettingsPatch.changedPaths(["network": [["mode": "nat"]]], more) == ["network"])
    #expect(SettingsPatch.changedPaths(old, old).isEmpty)
}

@Test func settingKindsFollowTheLiveMatrix() {
    #expect(SettingsPatch.kind(of: "id") == .immutable)
    #expect(SettingsPatch.kind(of: "disks") == .immutable)
    #expect(SettingsPatch.kind(of: "platform.machineIdentifier") == .immutable)
    #expect(SettingsPatch.kind(of: "name") == .host)
    #expect(SettingsPatch.kind(of: "mcp.policy") == .host)
    #expect(SettingsPatch.kind(of: "clipboard.allowWithAgents") == .host)
    #expect(SettingsPatch.kind(of: "clipboard.mode") == .nextBoot)
    #expect(SettingsPatch.kind(of: "shares") == .live)
    #expect(SettingsPatch.kind(of: "display.widthPx") == .live)
    #expect(SettingsPatch.kind(of: "display.ppi") == .nextBoot)
    #expect(SettingsPatch.kind(of: "network.0.mode") == .live)
    #expect(SettingsPatch.kind(of: "network.0.macAddress") == .nextBoot)
    #expect(SettingsPatch.kind(of: "network") == .nextBoot)
    #expect(SettingsPatch.kind(of: "cpu.count") == .nextBoot)
    #expect(SettingsPatch.kind(of: "audio.output") == .nextBoot)
    #expect(SettingsPatch.kind(of: "bogus") == .unknown)
}

@Test func copyTakesOneSettingAcrossIncludingRemovals() {
    let source: JSONValue = ["cpu": ["count": 4], "network": [["mode": "none"]], "ui": ["closeAction": "stop"]]
    let target: JSONValue = ["cpu": ["count": 2], "network": [["mode": "nat"]], "ui": ["closeAction": "stop", "icon": "x"]]
    var result = SettingsPatch.copy("cpu.count", from: source, into: target)
    result = SettingsPatch.copy("network.0.mode", from: source, into: result)
    result = SettingsPatch.copy("ui.icon", from: source, into: result)  // absent in source: removed
    #expect(result == ["cpu": ["count": 4], "network": [["mode": "none"]], "ui": ["closeAction": "stop"]])
}
