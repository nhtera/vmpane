import Testing
@testable import VMPaneHost

@Test func helperKnowsBothBackends() { #expect(HelperInfo.backends == ["vz", "qemu"]) }
