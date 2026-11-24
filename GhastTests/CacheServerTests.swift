import Foundation
import Synchronization
import Testing
@testable import Ghast

/// The interface list a test controls.
final class FakeInterfaces: InterfaceAddressListing, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [InterfaceAddress]

    init(_ list: [InterfaceAddress]) { self.list = list }

    func set(_ list: [InterfaceAddress]) { lock.withLock { self.list = list } }
    func addresses() -> [InterfaceAddress] { lock.withLock { list } }
}

/// Records binds and closes; binding an address in `failing` throws. With `holdBinds`, each
/// bind waits for `releaseBinds`; `kill` stops an address's latest listener on its own.
actor FakeBinder: CacheListenerBinding {
    struct Listener: CacheListening {
        let address: String
        let binder: FakeBinder
        let life: Life
        var isRunning: Bool { life.isAlive }
        func close() async { await binder.closed(address) }
    }

    final class Life: Sendable {
        private let alive = Mutex(true)
        var isAlive: Bool { alive.withLock { $0 } }
        func end() { alive.withLock { $0 = false } }
    }

    private(set) var binds: [(address: String, port: Int, peers: CacheSubnet)] = []
    private(set) var closes: [String] = []
    var failing: Set<String> = []
    private var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var lives: [String: Life] = [:]

    func fail(_ address: String) { failing.insert(address) }
    func closed(_ address: String) { closes.append(address) }
    func holdBinds() { holds = true }
    func kill(_ address: String) { lives[address]?.end() }

    func releaseBinds() {
        holds = false
        held.forEach { $0.resume() }
        held = []
    }

    /// Returns once a bind is waiting for `releaseBinds`.
    func waitForHeldBind() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func bind(address: String, port: Int, peers: CacheSubnet, responder: CacheResponder) async throws -> any CacheListening {
        if holds {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                heldWaiters.forEach { $0.resume() }
                heldWaiters = []
            }
        }
        if failing.contains(address) { throw POSIXError(.EADDRINUSE) }
        binds.append((address, port, peers))
        let life = Life()
        lives[address] = life
        return Listener(address: address, binder: self, life: life)
    }
}

@MainActor
@Suite("Cache server")
struct CacheServerTests {
    private let folder = CacheTestFolder()
    private let randomness = SequentialCacheRandomness()
    private let bridge = InterfaceAddress(name: "bridge100", address: "192.168.64.1", netmask: "255.255.255.248")
    private let secondBridge = InterfaceAddress(name: "bridge101", address: "192.168.65.1", netmask: "255.255.255.0")

    private func makeServer(_ interfaces: FakeInterfaces, binder: FakeBinder) throws -> CacheServer {
        randomness.port = 50123
        let store = try CacheStore(root: folder.url, clock: FakeClock(), randomness: randomness, writer: FileBlobWriter())
        return CacheServer(store: store, verifier: FakeCacheVerifier(), upstream: FakeUpstream(), randomness: randomness,
                           interfaces: interfaces, binder: binder)
    }

    @Test("the port is chosen once and kept across binds")
    func fixedPort() async throws {
        defer { folder.cleanup() }
        let interfaces = FakeInterfaces([bridge, secondBridge])
        let binder = FakeBinder()
        let server = try makeServer(interfaces, binder: binder)
        #expect(server.port == 50123)
        randomness.port = 60000

        _ = await server.endpoint(forGateway: bridge.address)
        let endpoint = try await server.endpoint(forGateway: secondBridge.address).get()

        #expect(server.port == 50123)
        #expect(endpoint == CacheEndpoint(address: "192.168.65.1", port: 50123))
        #expect(await binder.binds.map(\.port) == [50123, 50123])
    }

    @Test("two VMs asking at once share one bind and both get the working listener")
    func concurrentEndpoints() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        await binder.holdBinds()

        async let first = server.endpoint(forGateway: bridge.address)
        async let second = server.endpoint(forGateway: bridge.address)
        await binder.waitForHeldBind()
        for _ in 0..<50 { await Task.yield() }  // lets the second call join the pending bind
        await binder.releaseBinds()
        let results = await [first, second]

        let expected = CacheEndpoint(address: bridge.address, port: server.port)
        #expect(results.map { try? $0.get() } == [expected, expected])
        #expect(await binder.binds.count == 1)
        #expect(await binder.closes.isEmpty)
        #expect(server.boundAddresses == [bridge.address])
    }

    @Test("a listener that stopped on its own is closed and bound again on the next ask")
    func deadListenerRebinds() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        _ = try await server.endpoint(forGateway: bridge.address).get()

        await binder.kill(bridge.address)
        let again = await server.endpoint(forGateway: bridge.address)

        #expect(try again.get() == CacheEndpoint(address: bridge.address, port: server.port))
        #expect(await binder.binds.count == 2)
        #expect(await binder.closes == [bridge.address])
    }

    @Test("each bridge address gets one listener, bound once")
    func listenerPerAddress() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge, secondBridge]), binder: binder)

        _ = await server.endpoint(forGateway: bridge.address)
        _ = await server.endpoint(forGateway: bridge.address)
        _ = await server.endpoint(forGateway: secondBridge.address)

        #expect(await binder.binds.map(\.address) == ["192.168.64.1", "192.168.65.1"])
        #expect(server.boundAddresses == ["192.168.64.1", "192.168.65.1"])
    }

    @Test("concurrent requests for one address bind it once")
    func concurrentBind() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        async let first = server.endpoint(forGateway: bridge.address)
        async let second = server.endpoint(forGateway: bridge.address)
        let results = await [first, second]
        #expect(results.allSatisfy { (try? $0.get()) != nil })
        #expect(await binder.binds.count == 1)
    }

    @Test("each listener only admits peers from its bridge's subnet")
    func peersFromBridgeSubnet() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge, secondBridge]), binder: binder)
        _ = await server.endpoint(forGateway: bridge.address)
        _ = await server.endpoint(forGateway: secondBridge.address)
        #expect(await binder.binds.map(\.peers) == [
            try #require(CacheSubnet(address: "192.168.64.1", netmask: "255.255.255.248")),
            try #require(CacheSubnet(address: "192.168.65.1", netmask: "255.255.255.0")),
        ])
    }

    @Test("a listener is rebound when its bridge's subnet changes")
    func rebindsOnSubnetChange() async throws {
        defer { folder.cleanup() }
        let interfaces = FakeInterfaces([bridge])
        let binder = FakeBinder()
        let server = try makeServer(interfaces, binder: binder)
        _ = await server.endpoint(forGateway: bridge.address)

        interfaces.set([InterfaceAddress(name: "bridge100", address: "192.168.64.1", netmask: "255.255.255.0")])
        _ = await server.endpoint(forGateway: bridge.address)

        #expect(await binder.closes == ["192.168.64.1"])
        #expect(await binder.binds.map(\.peers.netmask) == ["255.255.255.248", "255.255.255.0"])
    }

    @Test("a bridge with an unusable netmask is never bound")
    func refusesBadNetmask() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([InterfaceAddress(name: "bridge100", address: "192.168.64.1", netmask: "0.255.0.0")]),
                                    binder: binder)
        let result = await server.endpoint(forGateway: "192.168.64.1")
        #expect(throws: CacheUnavailable.self) { try result.get() }
        #expect(await binder.binds.isEmpty)
    }

    @Test("a listener whose address is gone is closed on the next call")
    func closesVanished() async throws {
        defer { folder.cleanup() }
        let interfaces = FakeInterfaces([bridge])
        let binder = FakeBinder()
        let server = try makeServer(interfaces, binder: binder)
        _ = await server.endpoint(forGateway: bridge.address)

        interfaces.set([secondBridge])
        _ = await server.endpoint(forGateway: secondBridge.address)

        #expect(await binder.closes == ["192.168.64.1"])
        #expect(server.boundAddresses == ["192.168.65.1"])
    }

    @Test("only a VM bridge address is ever bound", arguments: [
        ("en0", "10.0.2.10"), ("lo0", "127.0.0.1"), ("bridge100", "0.0.0.0"), ("utun3", "100.64.0.1"),
    ])
    func refusesNonBridge(name: String, address: String) async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([InterfaceAddress(name: name, address: address, netmask: "255.255.255.0")]), binder: binder)
        let result = await server.endpoint(forGateway: address)
        #expect(throws: CacheUnavailable.self) { try result.get() }
        #expect(await binder.binds.isEmpty)
    }

    @Test("a gateway that isn't a local IPv4 literal is refused",
          arguments: ["192.168.64.9", "localhost", "", "192.168.64.1 ", "::1", "192.168.064.1"])
    func refusesUnknownAddress(gateway: String) async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let result = await server.endpoint(forGateway: gateway)
        #expect(throws: CacheUnavailable.self) { try result.get() }
        #expect(await binder.binds.isEmpty)
    }

    @Test("a bind failure is reported and leaves other listeners running")
    func bindFailure() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        await binder.fail(secondBridge.address)
        let server = try makeServer(FakeInterfaces([bridge, secondBridge]), binder: binder)
        _ = await server.endpoint(forGateway: bridge.address)

        let result = await server.endpoint(forGateway: secondBridge.address)

        guard case .failure(.bindFailed(let address, _)) = result else {
            Issue.record("expected a bind failure, got \(result)")
            return
        }
        #expect(address == "192.168.65.1")
        #expect(await binder.closes.isEmpty)
        #expect(server.boundAddresses == ["192.168.64.1"])
    }

    @Test("stop closes every listener and ends every VM's events")
    func stopClosesAll() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge, secondBridge]), binder: binder)
        _ = await server.endpoint(forGateway: bridge.address)
        _ = await server.endpoint(forGateway: secondBridge.address)
        let registration = server.registerVM()

        await server.stop()

        #expect(Set(await binder.closes) == ["192.168.64.1", "192.168.65.1"])
        var events = 0
        for await _ in registration.events { events += 1 }
        #expect(events == 0)
    }
}
