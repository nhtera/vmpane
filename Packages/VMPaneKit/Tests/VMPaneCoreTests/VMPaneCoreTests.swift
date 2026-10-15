import Foundation
import Testing

@testable import VMPaneCore

@Test func signingIdentifiersAreDistinct() {
    let ids = [VMPane.SigningIdentifier.app, VMPane.SigningIdentifier.helper, VMPane.SigningIdentifier.cli]
    #expect(Set(ids).count == ids.count)
    #expect(ids.allSatisfy { $0.hasPrefix("app.vmpane.mac") })
}

@Test func hostMemoryWarnsBelowAReserveAndClearsAboveTwice() {
    let gib: UInt64 = 1 << 30
    // A 16 GB Mac keeps 1 GB (more than 3 %); a 64 GB Mac keeps 3 % (1.92 GB).
    #expect(HostMemory(availableBytes: gib - 1, physicalBytes: 16 * gib).nearlyOut)
    #expect(!HostMemory(availableBytes: gib, physicalBytes: 16 * gib).nearlyOut)
    #expect(!HostMemory(availableBytes: 2 * gib - 1, physicalBytes: 16 * gib).recovered)
    #expect(HostMemory(availableBytes: 2 * gib, physicalBytes: 16 * gib).recovered)
    #expect(HostMemory(availableBytes: 3 * gib / 2, physicalBytes: 64 * gib).nearlyOut)
    #expect(HostMemory(availableBytes: 4 * gib, physicalBytes: 64 * gib).tooLow(forGuest: 8 * gib))
    #expect(!HostMemory(availableBytes: 8 * gib, physicalBytes: 64 * gib).tooLow(forGuest: 8 * gib))
}

@Test func hostMemoryReadsThisMac() throws {
    let host = try #require(HostMemory.current())
    #expect(host.physicalBytes == ProcessInfo.processInfo.physicalMemory)
    #expect(host.availableBytes > 0 && host.availableBytes <= host.physicalBytes)
}
