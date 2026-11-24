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

/// Records binds and closes, as `address:port`; binding a key (or address) in `failing` throws.
/// With `holdBinds`, each bind waits for `releaseBinds`; `kill` stops a listener on its own.
actor FakeBinder: CacheListenerBinding {
    struct Listener: CacheListening {
        let key: String
        let binder: FakeBinder
        let life: Life
        var isRunning: Bool { life.isAlive }
        func close() async { await binder.closed(key) }
    }

    final class Life: Sendable {
        private let alive = Mutex(true)
        var isAlive: Bool { alive.withLock { $0 } }
        func end() { alive.withLock { $0 = false } }
    }

    private(set) var binds: [(address: String, port: Int, peers: CacheSubnet)] = []
    private(set) var closes: [String] = []
    private var failing: Set<String> = []
    private var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var lives: [String: Life] = [:]

    var bound: [String] { binds.map { "\($0.address):\($0.port)" } }
    func fail(_ key: String) { failing.insert(key) }
    func closed(_ key: String) { closes.append(key) }
    func holdBinds() { holds = true }
    func kill(_ key: String) { lives[key]?.end() }

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
        let key = "\(address):\(port)"
        if failing.contains(key) || failing.contains(address) { throw POSIXError(.EADDRINUSE) }
        binds.append((address, port, peers))
        let life = Life()
        lives[key] = life
        return Listener(key: key, binder: self, life: life)
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

    /// Lets the server's background closes run.
    private func drain(_ server: CacheServer) async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("each VM gets its own port at registration, and its listener on that port")
    func portPerVM() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge, secondBridge]), binder: binder)
        let first = server.registerVM(), second = server.registerVM()

        let firstEndpoint = try await server.endpoint(forVM: first.id, gateway: bridge.address).get()
        let secondEndpoint = try await server.endpoint(forVM: second.id, gateway: bridge.address).get()

        #expect(first.port != second.port)
        #expect(firstEndpoint == CacheEndpoint(address: bridge.address, port: first.port))
        #expect(secondEndpoint == CacheEndpoint(address: bridge.address, port: second.port))
        #expect(firstEndpoint.resultsURL.absoluteString == "http://192.168.64.1:\(first.port)/")
        #expect(await binder.bound == ["192.168.64.1:\(first.port)", "192.168.64.1:\(second.port)"])
    }

    @Test("a port a registered VM holds is never handed to another")
    func portsAreUnique() async throws {
        defer { folder.cleanup() }
        let server = try makeServer(FakeInterfaces([bridge]), binder: FakeBinder())
        randomness.ports = [50200, 50200, 50200, 50201]
        let first = server.registerVM(), second = server.registerVM()
        #expect(first.port == 50200)
        #expect(second.port == 50201)
    }

    @Test("two asks for one VM's endpoint at once share one bind")
    func concurrentEndpoints() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let vm = server.registerVM()
        await binder.holdBinds()

        async let first = server.endpoint(forVM: vm.id, gateway: bridge.address)
        async let second = server.endpoint(forVM: vm.id, gateway: bridge.address)
        await binder.waitForHeldBind()
        for _ in 0..<50 { await Task.yield() }  // lets the second call join the pending bind
        await binder.releaseBinds()
        let results = await [first, second]

        let expected = CacheEndpoint(address: bridge.address, port: vm.port)
        #expect(results.map { try? $0.get() } == [expected, expected])
        #expect(await binder.binds.count == 1)
        #expect(server.boundEndpoints == ["192.168.64.1:\(vm.port)"])
    }

    @Test("a listener that stopped on its own is closed and bound again on the next ask")
    func deadListenerRebinds() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let vm = server.registerVM()
        _ = try await server.endpoint(forVM: vm.id, gateway: bridge.address).get()

        await binder.kill("192.168.64.1:\(vm.port)")
        let again = await server.endpoint(forVM: vm.id, gateway: bridge.address)
        await drain(server)

        #expect(try again.get() == CacheEndpoint(address: bridge.address, port: vm.port))
        #expect(await binder.binds.count == 2)
        #expect(await binder.closes == ["192.168.64.1:\(vm.port)"])
    }

    @Test("each listener only admits peers from its bridge's subnet")
    func peersFromBridgeSubnet() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge, secondBridge]), binder: binder)
        let first = server.registerVM(), second = server.registerVM()
        _ = await server.endpoint(forVM: first.id, gateway: bridge.address)
        _ = await server.endpoint(forVM: second.id, gateway: secondBridge.address)
        #expect(await binder.binds.map(\.peers) == [
            try #require(CacheSubnet(address: "192.168.64.1", netmask: "255.255.255.248")),
            try #require(CacheSubnet(address: "192.168.65.1", netmask: "255.255.255.0")),
        ])
    }

    @Test("a VM's listener is rebound when its bridge's subnet changes")
    func rebindsOnSubnetChange() async throws {
        defer { folder.cleanup() }
        let interfaces = FakeInterfaces([bridge])
        let binder = FakeBinder()
        let server = try makeServer(interfaces, binder: binder)
        let vm = server.registerVM()
        _ = await server.endpoint(forVM: vm.id, gateway: bridge.address)

        interfaces.set([InterfaceAddress(name: "bridge100", address: "192.168.64.1", netmask: "255.255.255.0")])
        _ = await server.endpoint(forVM: vm.id, gateway: bridge.address)
        await drain(server)

        #expect(await binder.closes == ["192.168.64.1:\(vm.port)"])
        #expect(await binder.binds.map(\.peers.netmask) == ["255.255.255.248", "255.255.255.0"])
    }

    @Test("a bridge with an unusable netmask is never bound")
    func refusesBadNetmask() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([InterfaceAddress(name: "bridge100", address: "192.168.64.1", netmask: "0.255.0.0")]),
                                    binder: binder)
        let result = await server.endpoint(forVM: server.registerVM().id, gateway: "192.168.64.1")
        #expect(throws: CacheUnavailable.self) { try result.get() }
        #expect(await binder.binds.isEmpty)
    }

    @Test("only a VM bridge address is ever bound", arguments: [
        ("en0", "10.0.2.10"), ("lo0", "127.0.0.1"), ("bridge100", "0.0.0.0"), ("utun3", "100.64.0.1"),
    ])
    func refusesNonBridge(name: String, address: String) async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([InterfaceAddress(name: name, address: address, netmask: "255.255.255.0")]), binder: binder)
        let result = await server.endpoint(forVM: server.registerVM().id, gateway: address)
        #expect(throws: CacheUnavailable.self) { try result.get() }
        #expect(await binder.binds.isEmpty)
    }

    @Test("a gateway that isn't a local IPv4 literal is refused",
          arguments: ["192.168.64.9", "localhost", "", "192.168.64.1 ", "::1", "192.168.064.1"])
    func refusesUnknownAddress(gateway: String) async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let result = await server.endpoint(forVM: server.registerVM().id, gateway: gateway)
        #expect(throws: CacheUnavailable.self) { try result.get() }
        #expect(await binder.binds.isEmpty)
    }

    @Test("a VM that isn't registered gets no listener")
    func refusesUnregistered() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let vm = server.registerVM()
        server.unregisterVM(vm.id)

        let result = await server.endpoint(forVM: vm.id, gateway: bridge.address)

        #expect(throws: CacheUnavailable.notRegistered) { try result.get() }
        #expect(await binder.binds.isEmpty)
    }

    @Test("a port that's taken is reported and leaves other VMs' listeners running")
    func bindFailure() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let first = server.registerVM(), second = server.registerVM()
        await binder.fail("192.168.64.1:\(second.port)")
        _ = await server.endpoint(forVM: first.id, gateway: bridge.address)

        let result = await server.endpoint(forVM: second.id, gateway: bridge.address)

        guard case .failure(.bindFailed(let address, _)) = result else {
            Issue.record("expected a bind failure, got \(result)")
            return
        }
        #expect(address == "192.168.64.1")
        #expect(await binder.closes.isEmpty)
        #expect(server.boundEndpoints == ["192.168.64.1:\(first.port)"])
    }

    @Test("unregistering a VM closes its listener and ends its events, and leaves others open")
    func unregisterCloses() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let first = server.registerVM(), second = server.registerVM()
        _ = await server.endpoint(forVM: first.id, gateway: bridge.address)
        _ = await server.endpoint(forVM: second.id, gateway: bridge.address)

        server.unregisterVM(first.id)
        await drain(server)

        #expect(await binder.closes == ["192.168.64.1:\(first.port)"])
        #expect(server.boundEndpoints == ["192.168.64.1:\(second.port)"])
        var events = 0
        for await _ in first.events { events += 1 }
        #expect(events == 0)
    }

    @Test("a VM that unregisters while its port is being bound gets no listener, and the bind is closed")
    func unregisterDuringBind() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge]), binder: binder)
        let vm = server.registerVM()
        await binder.holdBinds()

        async let result = server.endpoint(forVM: vm.id, gateway: bridge.address)
        await binder.waitForHeldBind()
        server.unregisterVM(vm.id)
        await binder.releaseBinds()

        let outcome = await result
        #expect(throws: CacheUnavailable.notRegistered) { try outcome.get() }
        await server.stop()
        #expect(await binder.closes == ["192.168.64.1:\(vm.port)"])
        #expect(server.boundEndpoints.isEmpty)
    }

    @Test("stop closes every listener and ends every VM's events")
    func stopClosesAll() async throws {
        defer { folder.cleanup() }
        let binder = FakeBinder()
        let server = try makeServer(FakeInterfaces([bridge, secondBridge]), binder: binder)
        let first = server.registerVM(), second = server.registerVM()
        _ = await server.endpoint(forVM: first.id, gateway: bridge.address)
        _ = await server.endpoint(forVM: second.id, gateway: secondBridge.address)

        await server.stop()

        #expect(Set(await binder.closes) == ["192.168.64.1:\(first.port)", "192.168.65.1:\(second.port)"])
        for registration in [first, second] {
            var events = 0
            for await _ in registration.events { events += 1 }
            #expect(events == 0)
        }
    }
}
