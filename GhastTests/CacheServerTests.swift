import Foundation
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

/// Records binds and closes; binding an address in `failing` throws.
actor FakeBinder: CacheListenerBinding {
    struct Listener: CacheListening {
        let address: String
        let binder: FakeBinder
        func close() async { await binder.closed(address) }
    }

    private(set) var binds: [(address: String, port: Int)] = []
    private(set) var closes: [String] = []
    var failing: Set<String> = []

    func fail(_ address: String) { failing.insert(address) }
    func closed(_ address: String) { closes.append(address) }

    func bind(address: String, port: Int, responder: CacheResponder) async throws -> any CacheListening {
        if failing.contains(address) { throw POSIXError(.EADDRINUSE) }
        binds.append((address, port))
        return Listener(address: address, binder: self)
    }
}

@MainActor
@Suite("Cache server")
struct CacheServerTests {
    private let folder = CacheTestFolder()
    private let randomness = SequentialCacheRandomness()
    private let bridge = InterfaceAddress(name: "bridge100", address: "192.168.64.1")
    private let secondBridge = InterfaceAddress(name: "bridge101", address: "192.168.65.1")

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
        let server = try makeServer(FakeInterfaces([InterfaceAddress(name: name, address: address)]), binder: binder)
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
