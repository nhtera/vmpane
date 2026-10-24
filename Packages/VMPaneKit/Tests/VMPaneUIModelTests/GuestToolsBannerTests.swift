import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneUI

// The window's offer to install the guest tools (HelperViewModel+GuestTools).

/// A model of a running VM of `os`, its helper and its id (its own, so a Don't Ask Again stays with this test).
@MainActor
private struct RunningVM {
    let model: HelperViewModel
    let channel: FakeChannel
    let id: String
}

@MainActor
private func runningVM(_ os: GuestOS, agent: JSONValue = ["connected": false]) async -> RunningVM {
    let channel = FakeChannel()
    let id = UUID().uuidString
    channel.answer("vm.info", .success(["state": "running", "os": .string(os.rawValue), "id": .string(id), "allowedRequests": []]))
    channel.answer("agent.status", .success(agent))
    let model = HelperViewModel(channel: channel)
    await model.start()
    return RunningVM(model: model, channel: channel, id: id)
}

@Test @MainActor func aVMWithoutToolsIsOfferedThemOnceItRanAWhile() async {
    let vm = await runningVM(.linux)
    let (model, channel, id) = (vm.model, vm.channel, vm.id)
    defer { UserDefaults.standard.removeObject(forKey: "guestToolsBannerDismissed.\(id)") }
    #expect(model.toolsBanner == nil)  // not straight away: it may be booting
    model.guestTools.waited = true
    #expect(model.toolsBanner == .install(.linux))
    model.closeToolsBanner(forever: false)
    #expect(model.toolsBanner == nil)
    model.showToolsBanner()  // the menu brings it back
    #expect(model.toolsBanner == .install(.linux))
    channel.push("install.progress", ["phase": "install", "percent": 10, "message": "Installing"])
    #expect(await eventually { model.toolsBanner == nil })  // never during an install
}

@Test @MainActor func dontAskAgainHoldsForTheVMButTheMenuStillOffersIt() async {
    let vm = await runningVM(.windows)
    let (model, id) = (vm.model, vm.id)
    defer { UserDefaults.standard.removeObject(forKey: "guestToolsBannerDismissed.\(id)") }
    model.guestTools.waited = true
    model.closeToolsBanner(forever: true)
    model.guestTools.closed = false  // another window of the same VM
    #expect(model.toolsBanner == nil)
    model.showToolsBanner()
    #expect(model.toolsBanner == .install(.windows))
}

@Test @MainActor func aConnectedAgentEndsTheOfferAndAnOlderMacOSOneIsUpdatedByHand() async {
    let vm = await runningVM(.linux)
    let (model, channel) = (vm.model, vm.channel)
    model.guestTools.waited = true
    channel.answer("agent.status", .success(["connected": true, "outdated": false]))
    channel.push("agent.connectionChanged", ["connected": true])
    #expect(await eventually { model.agentConnected && model.toolsBanner == nil })

    let mac = await runningVM(.macos, agent: ["connected": true, "outdated": true]).model
    #expect(mac.guestTools.outdated)
    #expect(mac.toolsBanner == .updateByHand)
}

@Test @MainActor func theBannersActionsAskTheHelper() async {
    let vm = await runningVM(.windows)
    let (model, channel) = (vm.model, vm.channel)
    await model.attachToolsDisc()
    #expect(channel.calls.contains("vm.tools.attach") && model.guestTools.discAttached)
    await model.typeToolsCommand()
    #expect(channel.params(of: "vm.input.text") == ["text": .string(HelperViewModel.linuxToolsCommand)])
    // Update Guest Tools without the tools: the offer instead.
    await model.updateGuestTools()
    #expect(model.guestTools.requested && !channel.calls.contains("vm.tools.update"))
}

@Test @MainActor func updateGuestToolsUpdatesAnOlderAgentOrSaysTheyAreCurrent() async {
    let older = await runningVM(.linux, agent: ["connected": true, "outdated": true])
    let (model, channel) = (older.model, older.channel)
    await model.updateGuestTools()
    #expect(channel.calls.contains("vm.tools.update"))
    let upToDate = await runningVM(.linux, agent: ["connected": true, "outdated": false])
    let (current, currentChannel) = (upToDate.model, upToDate.channel)
    await current.updateGuestTools()
    #expect(!currentChannel.calls.contains("vm.tools.update") && current.notice == "The guest tools are up to date")
}

@Test @MainActor func theOfferWaitsAgainAfterTheAgentCameAndNeverComesDuringAnInstall() async {
    let vm = await runningVM(.linux)
    let (model, channel) = (vm.model, vm.channel)
    model.guestTools.waited = true
    channel.push("agent.connectionChanged", ["connected": true])
    #expect(await eventually { model.agentConnected })
    channel.push("agent.connectionChanged", ["connected": false])  // e.g. the agent restarts for an update
    #expect(await eventually { !model.agentConnected })
    #expect(model.toolsBanner == nil)  // not straight away: a new wait first
    model.guestTools.waited = true
    model.guestTools.installing = true  // a Linux ISO's live installer, a cloud image's first boot
    #expect(model.toolsBanner == nil)
    model.guestTools.installing = false
    model.guestTools.shareless = true  // a Linux VM on QEMU has no vmpane-tools share
    #expect(model.toolsBanner == nil)
}

@Test @MainActor func theMenuOffersTheToolsOnlyToARunningVMWithoutThem() async {
    let vm = await runningVM(.linux, agent: ["connected": true, "outdated": false])
    vm.model.showToolsBanner()
    #expect(!vm.model.guestTools.requested && vm.model.notice == "The guest tools are installed")
}
