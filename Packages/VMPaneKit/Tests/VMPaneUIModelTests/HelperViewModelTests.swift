import AppKit
import Foundation
import Testing
import VMPaneControl
import VMPaneCore
import VMPaneHost

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

@Test @MainActor func windowFollowsTheHelpersEvents() async {
    let channel = FakeChannel()
    channel.answer("vm.info", .success(["state": "stopped", "allowedRequests": ["start"]]))
    channel.answer("agent.status", .success(["connected": false]))
    channel.answer("vm.settings.get", .success(["audio": ["output": true, "input": false]]))
    let model = HelperViewModel(channel: channel)
    await model.start()
    #expect(model.audioOutput && !model.audioInput)
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
    model.lastError = nil
    await model.cancelInstall()
    #expect(channel.calls.last == "vm.install.cancel" && model.lastError == nil)
    channel.answer("vm.install.cancel", .failure(RPCError(.invalidState, "the VM is starting; cancel the install once it runs")))
    await model.cancelInstall()
    #expect(model.lastError == "the VM is starting; cancel the install once it runs")
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
            ],
            "listening": [["proto": "tcp", "port": 8000, "process": "python3"], ["proto": "udp", "port": 5353]],
        ]))
    await model.refreshPorts()
    #expect(model.portStatuses["web"] == SettingsModel.PortStatus(state: "listening", reason: nil))
    #expect(model.portStatuses["dns"]?.reason == "bind: Address already in use")
    #expect(model.listening == [.init(proto: .tcp, port: 8000, process: "python3"), .init(proto: .udp, port: 5353, process: nil)])
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

/// The window's title is the VM's name and follows a rename; a snapshot taken from the toolbar is confirmed.
@Test @MainActor func windowNamesTheVMAndConfirmsASnapshot() async {
    let channel = FakeChannel()
    channel.answer("vm.info", .success(["state": "running", "name": "Ubuntu", "allowedRequests": ["pause", "stop"]]))
    let model = HelperViewModel(channel: channel)
    await model.start()
    #expect(model.name == "Ubuntu")
    channel.answer("vm.info", .success(["state": "running", "name": "Ubuntu Dev", "allowedRequests": ["pause", "stop"]]))
    await model.refresh()  // as when the settings sheet closes
    #expect(model.name == "Ubuntu Dev")

    #expect(model.notice == nil)
    await model.perform(.snapshot)
    #expect(model.notice == "Snapshot taken")
    channel.answer("vm.snapshot.create", .failure(RPCError(.invalidState, "no")))
    model.notice = nil
    await model.perform(.snapshot)
    #expect(model.notice == nil && model.lastError == "no")
}

/// While a snapshot is being taken its button waits, so a double click takes one snapshot.
@Test @MainActor func theSnapshotButtonWaitsForTheSnapshot() async {
    let channel = SlowChannel()
    channel.answer("vm.info", .success(["state": "running", "allowedRequests": ["pause", "stop"]]))
    let model = HelperViewModel(channel: channel)
    await model.start()
    #expect(model.can(.snapshot))
    let taking = Task { await model.perform(.snapshot) }
    #expect(await eventually { model.takingSnapshot && !model.can(.snapshot) })
    await taking.value
    #expect(model.can(.snapshot))
}

/// `vm.snapshot.create` takes a moment.
final class SlowChannel: HelperChannel, @unchecked Sendable {
    let inner = FakeChannel()
    var notifications: AsyncStream<RPCRequest> { inner.notifications }
    func answer(_ method: String, _ result: Result<JSONValue, RPCError>) { inner.answer(method, result) }
    func call(_ method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        if method == "vm.snapshot.create" { try await Task.sleep(for: .milliseconds(300)) }
        return try await inner.call(method, params: params, timeout: timeout)
    }
}

/// What a low-memory guard was asked, and its answer.
@MainActor
final class LowMemoryAnswers {
    var asked: [LowMemoryStart] = []
    var startAnyway = false

    /// A guard over a Mac with `memory` available (of 16 GB) that records each question.
    func guardOver(_ memory: MemoryBox) -> LowMemoryGuard {
        LowMemoryGuard(
            memory: { memory.host },
            confirm: { start in
                self.asked.append(start)
                return self.startAnyway
            })
    }
}

/// The Mac's memory as a test sets it.
final class MemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var available: UInt64

    init(available: UInt64) { self.available = available }
    func set(_ bytes: UInt64) { lock.withLock { available = bytes } }
    var host: HostMemory { lock.withLock { HostMemory(availableBytes: available, physicalBytes: 16 << 30) } }
}

@Test @MainActor func aStartOnAMacLowOnMemoryAsksFirst() async {
    let channel = FakeChannel()
    channel.answer("vm.info", .success(["state": "stopped", "name": "Dev", "allowedRequests": ["start"]]))
    channel.answer("vm.settings.get", .success(["memory": ["mib": 8192]]))
    let model = HelperViewModel(channel: channel)
    await model.start()
    let memory = MemoryBox(available: 2 << 30)
    let answers = LowMemoryAnswers()
    model.lowMemoryGuard = answers.guardOver(memory)

    await model.perform(.start)
    #expect(answers.asked == [LowMemoryStart(name: "Dev", guestBytes: 8 << 30, availableBytes: 2 << 30)])
    #expect(!channel.calls.contains("vm.start"), "Cancel leaves the VM off")

    answers.startAnyway = true
    await model.perform(.start)
    #expect(channel.calls.last == "vm.start")

    // With room for the VM it starts without a question.
    memory.set(12 << 30)
    await model.perform(.start)
    #expect(answers.asked.count == 2 && channel.calls.last == "vm.start")
}

@Test @MainActor func theWindowWarnsWhileTheMacIsNearlyOutOfMemory() async {
    let channel = FakeChannel()
    channel.answer("vm.info", .success(["state": "running", "allowedRequests": ["stop"]]))
    let model = HelperViewModel(channel: channel)
    await model.start()
    let memory = MemoryBox(available: 8 << 30)
    model.lowMemoryGuard = LowMemoryAnswers().guardOver(memory)
    let watch = Task { await model.watchMemory(every: .milliseconds(10)) }
    defer { watch.cancel() }

    try? await Task.sleep(for: .milliseconds(50))
    #expect(!model.memoryLow)
    memory.set(512 << 20)  // under 1 GB
    #expect(await eventually { model.memoryLow })
    memory.set(1536 << 20)  // above 1 GB but under 2: the warning stays (no flicker at the edge)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(model.memoryLow)
    memory.set(3 << 30)
    #expect(await eventually { !model.memoryLow })

    memory.set(512 << 20)
    #expect(await eventually { model.memoryLow })
    channel.answer("vm.info", .success(["state": "stopped", "allowedRequests": ["start"]]))
    channel.push("vm.stateChanged", ["state": "stopped"])
    #expect(await eventually { !model.memoryLow }, "a stopped VM shows no warning")
}

@Test @MainActor func theAccessibilityHintShowsOncePerVM() async {
    let id = UUID().uuidString
    defer { UserDefaults.standard.removeObject(forKey: "accessibilityHintShown.\(id)") }
    let channel = FakeChannel()
    channel.answer("vm.info", .success(["id": .string(id), "state": "running", "os": "macos"]))
    let model = HelperViewModel(channel: channel)
    await model.start()
    channel.push("screen.accessibilityNeeded", [:])
    #expect(await eventually { model.notice == HelperViewModel.accessibilityHint })
    model.notice = nil
    channel.push("screen.accessibilityNeeded", [:])
    channel.push("agent.connectionChanged", ["connected": true])
    #expect(await eventually { model.agentConnected })
    #expect(model.notice == nil, "not twice for one VM")
}

/// The person's own key or click takes over only while an agent acts; the HUD's buttons call the helper.
@Test @MainActor func thePersonTakesOverOnlyWhileAnAgentActs() async throws {
    let channel = FakeChannel()
    let acting: JSONValue = ["acting": true, "client": "claude-code", "level": "exec", "current": "typing", "recent": []]
    channel.answer("vm.agent.takeOver", .success(["acting": false, "takenOver": true, "level": "exec", "recent": []]))
    channel.answer("vm.agent.resume", .success(["acting": false, "takenOver": false, "level": "exec", "recent": []]))
    let model = HelperViewModel(channel: channel)
    model.personActed()  // nobody acts: nothing happens
    try await Task.sleep(for: .milliseconds(50))
    #expect(!channel.calls.contains("vm.agent.takeOver"))
    model.show(AgentActivity(acting))
    #expect(model.activity?.client == "claude-code" && model.activity?.level == .exec && model.activity?.current == "typing")
    model.personActed()
    for _ in 0..<50 where model.activity?.takenOver != true { try await Task.sleep(for: .milliseconds(10)) }
    #expect(channel.calls.contains("vm.agent.takeOver") && model.activity?.takenOver == true)
    await model.resumeAgents()
    #expect(model.activity?.takenOver == false)
}

/// An approval in the window: Deny is a no, Allow Once a yes, a dismissed question a no.
@Test @MainActor func approvalsAreAnsweredInTheWindow() async {
    let model = HelperViewModel(channel: FakeChannel())
    let question = ConfirmationRequest(title: "An AI agent wants to run a command", detail: "rm -rf /tmp/x")
    async let allowed = model.presentApproval(question)
    await Task.yield()
    #expect(model.approval == question)
    model.answerApproval(true)
    #expect(await allowed && model.approval == nil)
    async let dismissed = model.presentApproval(question)
    await Task.yield()
    model.dismissApproval()
    #expect(await dismissed == false)
}
