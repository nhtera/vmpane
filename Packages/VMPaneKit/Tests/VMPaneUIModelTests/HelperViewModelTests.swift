import AppKit
import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneUI

/// A helper the test scripts: answers by method, records calls, pushes notifications.
final class FakeChannel: HelperChannel, @unchecked Sendable {
    let notifications: AsyncStream<RPCRequest>
    private let continuation: AsyncStream<RPCRequest>.Continuation
    private let lock = NSLock()
    private var answers: [String: Result<JSONValue, RPCError>] = [:]
    private var recorded: [String] = []
    private var lastParams: [String: JSONValue] = [:]

    init() {
        (notifications, continuation) = AsyncStream.makeStream(of: RPCRequest.self)
    }

    func answer(_ method: String, _ result: Result<JSONValue, RPCError>) { lock.withLock { answers[method] = result } }
    func push(_ method: String, _ params: JSONValue) { continuation.yield(RPCRequest(id: nil, method: method, params: params)) }
    var calls: [String] { lock.withLock { recorded } }
    func params(of method: String) -> JSONValue? { lock.withLock { lastParams[method] } }

    func call(_ method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        let answer = lock.withLock { () -> Result<JSONValue, RPCError> in
            recorded.append(method)
            if let params { lastParams[method] = params }
            return answers[method] ?? .success([:])
        }
        return try answer.get()
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Test @MainActor func windowFollowsTheHelpersEvents() async {
    let channel = FakeChannel()
    channel.answer("vm.info", .success(["state": "stopped", "allowedRequests": ["start"]]))
    channel.answer("agent.status", .success(["connected": false]))
    let model = HelperViewModel(channel: channel)
    await model.start()
    #expect(channel.calls.prefix(2) == ["events.subscribe", "vm.info"])
    #expect(channel.params(of: "events.subscribe") == ["topics": ["vm", "install", "agent", "files"]])
    #expect(model.state == .stopped && model.can(.start) && !model.can(.shutDown))

    channel.answer("vm.info", .success(["state": "running", "allowedRequests": ["pause", "suspend", "stop"]]))
    channel.push("vm.stateChanged", ["state": "running"])
    #expect(await eventually { model.state == .running && model.can(.shutDown) && !model.can(.start) })
    #expect(model.can(.snapshot))

    channel.push("install.progress", ["phase": "setupRunning", "percent": 40, "message": "Windows Setup is installing"])
    #expect(await eventually { model.install?.percent == 40 && model.install?.isActive == true })
    channel.push("install.progress", ["phase": "done", "percent": 100, "message": "Windows is installed"])
    #expect(await eventually { model.install?.isActive == false })

    channel.push("agent.connectionChanged", ["connected": true])
    #expect(await eventually { model.agentConnected })
    model.stop()
}

@Test @MainActor func actionsCallTheHelperAndKeepFailures() async {
    let channel = FakeChannel()
    let model = HelperViewModel(channel: channel)
    await model.perform(.shutDown)
    #expect(channel.params(of: "vm.stop") == ["mode": "graceful"])
    await model.perform(.snapshot)
    #expect(channel.params(of: "vm.snapshot.create")?["kind"] == "live")
    channel.answer("vm.suspend", .failure(RPCError(.invalidState, "a VM installing Windows cannot be suspended")))
    await model.perform(.suspend)
    #expect(model.lastError == "a VM installing Windows cannot be suspended")
}

@Test @MainActor func screenshotsLandAsPNGFiles() async throws {
    let channel = FakeChannel()
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    channel.answer("vm.screenshot", .success(["dataB64": .string(png.base64EncodedString()), "width": 4, "height": 3]))
    let directory = URL(fileURLWithPath: "/tmp/vp-shot-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = HelperViewModel(channel: channel)
    await model.screenshot(to: directory)
    let saved = try #require(model.lastScreenshot)
    #expect(try Data(contentsOf: saved) == png)
    #expect(saved.lastPathComponent.hasPrefix("VM Screenshot "))
}

@Test @MainActor func settingsSendOnePatchAndReportEachField() async throws {
    let channel = FakeChannel()
    var config = VMConfigV1(VMConfigFields.new(name: "VM", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    config.cpu.count = 2
    let model = SettingsModel(config: config, channel: channel)
    #expect(!model.hasChanges)
    model.draft.cpu.count = 4
    model.draft.name = "Renamed"
    #expect(model.changedPaths == ["cpu.count", "name"])
    #expect(SettingsModel.kind(of: "name") == .host)
    #expect(SettingsModel.kind(of: "display.scaling") == .nextBoot, "the SPICE window reads it at start")
    channel.answer("vm.settings.apply", .success(["fields": ["cpu.count": "nextBoot", "name": "applied"]]))
    await model.apply()
    #expect(channel.params(of: "vm.settings.apply") == ["patch": ["cpu": ["count": 4], "name": "Renamed"]])
    #expect(model.outcomes == ["cpu.count": .nextBoot, "name": .applied])
    #expect(model.needsRestart)
    #expect(!model.hasChanges, "the applied draft is the new baseline")
    #expect(model.original.cpu.count == 4)
}

@Test @MainActor func snapshotsListNewestFirstAndActionsReachTheHelper() async throws {
    let channel = FakeChannel()
    let older = UUID()
    let newer = UUID()
    func meta(_ id: UUID, _ name: String, _ date: String, _ kind: String) -> JSONValue {
        [
            "schemaVersion": 1, "id": .string(id.uuidString), "name": .string(name), "createdAt": .string(date), "kind": .string(kind),
            "generationId": .string(UUID().uuidString), "deviceSetHash": "h", "hostBuild": "24G419", "backendVersion": "0.1.0",
            "origin": "user", "sizeBytes": 4096,
        ]
    }
    channel.answer(
        "vm.snapshot.list",
        .success([meta(older, "Before update", "2026-10-01T10:00:00Z", "disk"), meta(newer, "Clean", "2026-10-11T10:00:00Z", "live")]))
    let model = SnapshotsModel(channel: channel)
    await model.reload()
    #expect(model.snapshots.map(\.name) == ["Clean", "Before update"])
    #expect(SnapshotsModel.restoreWarning(model.snapshots[0]).contains("running state"))
    await model.take(name: "x", running: false)
    #expect(channel.params(of: "vm.snapshot.create") == ["name": "x", "kind": "disk"])
    await model.restore(older)
    #expect(channel.params(of: "vm.snapshot.restore") == ["id": .string(older.uuidString)])
    channel.answer("vm.snapshot.delete", .failure(RPCError(.invalidParams, "no snapshot")))
    await model.delete(newer)
    #expect(model.lastError == "no snapshot")
}

@Test @MainActor func dockIconsDifferBySystemAndState() throws {
    func pixels(_ image: NSImage) throws -> Data {
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }
    let linux = try pixels(DockIcon.image(os: .linux, state: .running))
    #expect(linux != (try pixels(DockIcon.image(os: .windows, state: .running))))
    #expect(linux != (try pixels(DockIcon.image(os: .linux, state: .paused))))
    #expect(DockIcon.badge(.paused) == "Paused" && DockIcon.badge(.running) == nil)
}

@Test @MainActor func portStatusesComeFromTheHelper() async throws {
    let channel = FakeChannel()
    let config = VMConfigV1(VMConfigFields.new(name: "VM", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    let model = SettingsModel(config: config, channel: channel)
    channel.answer(
        "vm.ports.list",
        .success([
            "rules": [
                ["id": "web", "status": "listening"],
                ["id": "dns", "status": "failed", "reason": "bind: Address already in use"],
            ]
        ]))
    await model.refreshPorts()
    #expect(model.portStatuses["web"] == SettingsModel.PortStatus(state: "listening", reason: nil))
    #expect(model.portStatuses["dns"]?.reason == "bind: Address already in use")
}

@Test @MainActor func droppedFilesGoToTheHelperWithProgress() async throws {
    let channel = FakeChannel()
    let model = HelperViewModel(channel: channel)
    channel.answer("vm.files.drop", .success(["guestPath": "/home/u/Desktop/VMPane Drops/x", "files": 1]))
    model.transfer = HelperViewModel.Transfer(bytesDone: 0, bytesTotal: 0, file: "a")
    model.apply(RPCRequest(id: nil, method: "files.progress", params: ["bytesDone": 5, "bytesTotal": 10, "file": "a"]))
    #expect(model.transfer?.fraction == 0.5)
    model.transfer = nil
    await model.drop([URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")])
    #expect(channel.params(of: "vm.files.drop") == ["paths": ["/tmp/a", "/tmp/b"]])
    #expect(model.transfer == nil && model.lastError == nil)
}
