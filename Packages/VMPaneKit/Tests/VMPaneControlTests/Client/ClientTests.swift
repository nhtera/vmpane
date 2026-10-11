import Foundation
import Testing
import VMPaneControl

@testable import VMPaneCore

private func item(_ name: String, _ id: String) throws -> VMLibrary.Item {
    let uuid = try #require(UUID(uuidString: id))
    var config = VMConfigV1(VMConfigFields.new(name: name, os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    config.id = uuid
    return VMLibrary.Item(id: uuid, bundle: VMBundle(uncheckedURL: URL(fileURLWithPath: "/tmp/\(name).vmpane")), config: config, error: nil)
}

@Test func vmsAreFoundByIdShortIdOrName() throws {
    let items = [
        try item("Ubuntu", "AB12CD34-0000-0000-0000-000000000001"), try item("ubuntu", "AB12CD35-0000-0000-0000-000000000002"),
        try item("Windows 11", "FF000000-0000-0000-0000-000000000003"),
    ]
    #expect(try VMSelector.resolve("ab12cd34-0000-0000-0000-000000000001", in: items).config?.name == "Ubuntu")
    #expect(try VMSelector.resolve("ab12cd35", in: items).config?.name == "ubuntu")
    #expect(try VMSelector.resolve("Ubuntu", in: items).config?.name == "Ubuntu", "an exact name wins")
    #expect(try VMSelector.resolve("windows 11", in: items).config?.name == "Windows 11", "case is ignored when unambiguous")
    #expect(throws: VMSelector.Failure.self) { try VMSelector.resolve("UBUNTU", in: items) }  // two by folded name
    #expect(throws: VMSelector.Failure.self) { try VMSelector.resolve("ab12", in: items) }  // two by id prefix
    #expect(throws: VMSelector.Failure.notFound("Debian")) { try VMSelector.resolve("Debian", in: items) }
}

@Test func errorsMapToExitCodes() {
    #expect(ExitStatus.of(RPCError(.policyDenied, "no")) == .policyDenied)
    #expect(ExitStatus.of(RPCError(.agentUnavailable, "no")) == .unavailable)
    #expect(ExitStatus.of(RPCError(.invalidState, "no")) == .tempFail)
    #expect(ExitStatus.of(RPCError(.internalError, "no")) == .failure)
    #expect(ExitStatus.policyDenied.rawValue == 77)
}

@Test func tablesAlignAndJSONIsSorted() {
    #expect(
        OutputFormatter.table(["NAME", "STATE"], [["Ubuntu", "running"], ["W", "stopped"]])
            == "NAME    STATE\nUbuntu  running\nW       stopped")
    #expect(OutputFormatter.json(["b": 1, "a": "x/y"]) == "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
}
