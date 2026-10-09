import Testing
@testable import VMPaneQEMU

@Test func backendName() { #expect(QEMUBackendInfo.name == "qemu") }
