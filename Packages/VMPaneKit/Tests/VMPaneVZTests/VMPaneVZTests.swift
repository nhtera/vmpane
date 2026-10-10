import Testing

@testable import VMPaneVZ

@Test func backendName() { #expect(VZBackendInfo.name == "vz") }
