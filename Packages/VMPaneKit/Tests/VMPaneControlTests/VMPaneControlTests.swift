import Testing
@testable import VMPaneControl

@Test func protocolFloorIsHonoured() {
    #expect(ControlProtocol.isCompatible(peerVersion: ControlProtocol.version))
    #expect(!ControlProtocol.isCompatible(peerVersion: ControlProtocol.minimumVersion - 1))
}
