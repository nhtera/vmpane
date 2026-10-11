import Foundation
import Testing

@testable import VMPaneHost

private let sample = """
    {
    \tname=vmpane-itest
    \tip_address=192.168.64.23
    \thw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:a6:6c:40:58:63:70:70:fa
    \tidentifier=ff,f1:f5:dd:7f:0:2:0:0:ab:11:a6:6c:40:58:63:70:70:fa
    \tlease=0x6acb49f0
    }
    {
    \tname=AppleViMachine1
    \tip_address=192.168.64.22
    \thw_address=1,52:54:0:97:60:1
    \tidentifier=1,52:54:0:97:60:1
    \tlease=0x6ac9c406
    }
    {
    \tname=broken
    \tip_address=192.168.64.300
    \thw_address=1,52:54:0:97:60:2
    \tlease=0x6ac9c406
    }
    {
    \tname=no-expiry
    \tip_address=192.168.64.30
    \thw_address=1,52:54:0:97:60:3
    }
    """

@Test func leasesKeepAddressMACAndExpiry() {
    let leases = DHCPLease.parse(sample)
    #expect(leases.map(\.ipAddress) == ["192.168.64.23", "192.168.64.22"])
    #expect(leases[0].macAddress == nil, "a DUID client id names no MAC")
    #expect(leases[1].macAddress == "52:54:00:97:60:01")
    #expect(leases[1].expiry == Date(timeIntervalSince1970: 0x6ac9_c406))
}

@Test func macAndIPv4ParsingIsStrict() {
    #expect(DHCPLease.canonicalMAC("A:b:0C:d:E:f") == "0a:0b:0c:0d:0e:0f")
    for bad in ["52:54:0:97:60", "52:54:0:97:60:1:2", "52:54:0:97:60:", "52:54:0:97:60:123", "52:54:0:97:60:g1"] {
        #expect(DHCPLease.canonicalMAC(bad) == nil, "\(bad)")
    }
    #expect(IPv4("192.168.64.1")?.description == "192.168.64.1")
    for bad in ["10.1", "1.2.3.4.5", "1.2.3.256", "1.2.3.-1", " 1.2.3.4", "1.2.3.4 ", "1..3.4", "１.2.3.4"] {
        #expect(IPv4(bad) == nil, "\(bad)")
    }
}
