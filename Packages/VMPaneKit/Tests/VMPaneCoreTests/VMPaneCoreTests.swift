import Testing
@testable import VMPaneCore

@Test func signingIdentifiersAreDistinct() {
    let ids = [VMPane.SigningIdentifier.app, VMPane.SigningIdentifier.helper, VMPane.SigningIdentifier.cli]
    #expect(Set(ids).count == ids.count)
    #expect(ids.allSatisfy { $0.hasPrefix("app.vmpane.mac") })
}
