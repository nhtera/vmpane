import Testing
@testable import VMPaneMCP

@Test func statelessRevisionIsPreferred() {
    #expect(MCPProtocol.supportedVersions.first == "2026-07-28")
    #expect(MCPProtocol.supportedVersions == MCPProtocol.supportedVersions.sorted(by: >))
}
