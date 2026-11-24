import Foundation
import Testing
@testable import Ghast

@Suite("Cache peer subnet")
struct CacheSubnetTests {
    private let bridge = try! #require(CacheSubnet(address: "192.168.64.1", netmask: "255.255.255.248"))

    @Test("hosts inside the bridge's /29 are peers", arguments: ["192.168.64.1", "192.168.64.2", "192.168.64.6"])
    func inside(remote: String) {
        #expect(bridge.contains(remote))
    }

    @Test("the network and broadcast addresses, neighbours and LAN hosts are not",
          arguments: ["192.168.64.0", "192.168.64.7", "192.168.64.8", "192.168.63.255", "192.168.65.1", "10.0.2.10",
                      "127.0.0.1", "0.0.0.0", "255.255.255.255", "::1", "::ffff:192.168.64.2", "192.168.64.2 ", "", "x"])
    func outside(remote: String) {
        #expect(!bridge.contains(remote))
    }

    @Test("a /24 bridge ends at .254")
    func wideBridge() throws {
        let subnet = try #require(CacheSubnet(address: "192.168.64.1", netmask: "255.255.255.0"))
        #expect(subnet.contains("192.168.64.254"))
        #expect(!subnet.contains("192.168.64.255"))
        #expect(!subnet.contains("192.168.65.2"))
    }

    @Test("a malformed or non-contiguous netmask makes no subnet",
          arguments: [("192.168.64.1", "255.0.255.0"), ("192.168.64.1", "x"), ("x", "255.255.255.0"), ("192.168.64.1", "")])
    func invalid(address: String, netmask: String) {
        #expect(CacheSubnet(address: address, netmask: netmask) == nil)
    }
}

@Suite("System interface addresses")
struct SystemInterfaceAddressesTests {
    @Test("loopback is listed with its netmask, which makes a usable subnet")
    func loopback() throws {
        let lo0 = try #require(SystemInterfaceAddresses().addresses().first { $0.name == "lo0" && $0.address == "127.0.0.1" })
        let subnet = try #require(CacheSubnet(address: lo0.address, netmask: lo0.netmask))
        #expect(subnet.contains("127.0.0.1"))
    }
}
