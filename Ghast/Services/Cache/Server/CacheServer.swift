import Darwin
import Foundation
import Hummingbird
import HummingbirdCore
import Logging

/// The cache's HTTP server. The port is chosen once, when the server is made, so it can go
/// on `tart run`'s argv before the VM's gateway is known. Each VM bridge address gets its
/// own listener on that port, bound when a VM first asks for it and closed once the address
/// is gone. Only `bridge*` addresses are ever bound: never a wildcard, loopback or LAN one.
@MainActor
final class CacheServer {
    let port: Int
    private let router: CacheRouter
    private let registry: CacheVMRegistry
    private let randomness: any CacheRandomness
    private let interfaces: any InterfaceAddressListing
    private let binder: any CacheListenerBinding
    private let allowsLoopback: Bool
    private var listeners: [String: any CacheListening] = [:]
    private var binding: [String: Task<Result<any CacheListening, CacheUnavailable>, Never>] = [:]

    convenience init(store: CacheStore, verifier: any CacheTokenVerifying, upstream: any UpstreamForwarding,
                     randomness: any CacheRandomness = SystemCacheRandomness(),
                     interfaces: any InterfaceAddressListing = SystemInterfaceAddresses(),
                     binder: any CacheListenerBinding = HummingbirdListenerBinder()) {
        self.init(store: store, verifier: verifier, upstream: upstream, randomness: randomness, interfaces: interfaces,
                  binder: binder, allowsLoopback: false)
    }

    #if DEBUG
    /// Test-only: also accepts `lo0` addresses so routing can be tested over real HTTP.
    convenience init(store: CacheStore, verifier: any CacheTokenVerifying, upstream: any UpstreamForwarding,
                     randomness: any CacheRandomness, interfaces: any InterfaceAddressListing,
                     binder: any CacheListenerBinding = HummingbirdListenerBinder(), allowLoopbackForTests: Bool) {
        self.init(store: store, verifier: verifier, upstream: upstream, randomness: randomness, interfaces: interfaces,
                  binder: binder, allowsLoopback: allowLoopbackForTests)
    }
    #endif

    private init(store: CacheStore, verifier: any CacheTokenVerifying, upstream: any UpstreamForwarding,
                 randomness: any CacheRandomness, interfaces: any InterfaceAddressListing,
                 binder: any CacheListenerBinding, allowsLoopback: Bool) {
        let registry = CacheVMRegistry()
        router = CacheRouter(twirp: CacheTwirpService(store: store, verifier: verifier),
                             upload: CacheBlobUploadHandler(store: store), download: CacheBlobDownloadHandler(store: store),
                             passthrough: CachePassthrough(upstream: upstream), registry: registry)
        self.registry = registry
        self.randomness = randomness
        self.interfaces = interfaces
        self.binder = binder
        self.allowsLoopback = allowsLoopback
        port = randomness.highPort()
    }

    var boundAddresses: [String] { listeners.keys.sorted() }

    /// Makes sure the port is open on `gateway` (a VM bridge address) and returns where the
    /// VM reaches it. Closes listeners whose address has gone first.
    func endpoint(forGateway gateway: String) async -> Result<CacheEndpoint, CacheUnavailable> {
        guard let address = Self.canonicalIPv4(gateway) else { return .failure(.invalidAddress(gateway)) }
        let live = Set(interfaces.addresses().filter(isBindable).map(\.address))
        await closeListeners(notIn: live)
        guard live.contains(address) else { return .failure(.addressNotLocalBridge(gateway)) }
        let endpoint = CacheEndpoint(address: address, port: port)
        guard listeners[address] == nil else { return .success(endpoint) }

        let task = binding[address] ?? startBinding(address)
        binding[address] = task
        let result = await task.value
        binding[address] = nil
        switch result {
        case .success(let listener):
            if listeners[address] == nil { listeners[address] = listener }
            return .success(endpoint)
        case .failure(let reason):
            return .failure(reason)
        }
    }

    /// Registers a VM; its token goes in the VM's results URL and its cache events arrive on
    /// `events` until `unregisterVM`.
    func registerVM() -> CacheVMRegistration {
        let token = randomness.id128()
        return CacheVMRegistration(token: token, events: registry.register(token))
    }

    func unregisterVM(_ token: String) {
        registry.unregister(token)
    }

    /// Closes every listener and ends every VM's events (app quit).
    func stop() async {
        registry.unregisterAll()
        let pending = binding.values
        binding.removeAll()
        for task in pending {
            if case .success(let listener) = await task.value { await listener.close() }
        }
        await closeListeners(notIn: [])
    }

    private func startBinding(_ address: String) -> Task<Result<any CacheListening, CacheUnavailable>, Never> {
        let binder = binder, port = port
        let responder = CacheResponder(router: router, serverBase: URL(string: "http://\(address):\(port)/")!)
        return Task {
            do {
                return .success(try await binder.bind(address: address, port: port, responder: responder))
            } catch {
                let reason = String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown error"
                return .failure(.bindFailed(address: address, reason: reason))
            }
        }
    }

    private func closeListeners(notIn live: Set<String>) async {
        let gone = listeners.filter { !live.contains($0.key) }
        gone.keys.forEach { listeners.removeValue(forKey: $0) }
        for listener in gone.values { await listener.close() }
    }

    private func isBindable(_ interface: InterfaceAddress) -> Bool {
        guard Self.canonicalIPv4(interface.address) != nil, interface.address != "0.0.0.0" else { return false }
        if interface.name.hasPrefix("bridge") { return true }
        return allowsLoopback && interface.name == "lo0" && interface.address.hasPrefix("127.")
    }

    /// `text` when it is a dotted-quad IPv4 address written canonically, else nil.
    static func canonicalIPv4(_ text: String) -> String? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let canonical = String(cString: buffer)
        return canonical == text ? canonical : nil
    }
}

/// Runs one Hummingbird HTTP/1.1 server per address, capped at 64 connections.
struct HummingbirdListenerBinder: CacheListenerBinding {
    var maximumConnections = 64

    func bind(address: String, port: Int, responder: CacheResponder) async throws -> any CacheListening {
        let started = StartSignal()
        var logger = Logger(label: "net.evancoleman.ghast.cache")
        logger.logLevel = .error
        let app = Application(
            responder: responder,
            configuration: .init(address: .hostname(address, port: port),
                                 availableConnectionsDelegate: MaximumAvailableConnections(maximumConnections)),
            onServerRunning: { _ in await started.resolve(nil) },
            logger: logger)
        let task = Task {
            do {
                try await app.run()
                await started.resolve(CancellationError())
            } catch {
                await started.resolve(error)
            }
        }
        if let error = await started.wait() {
            task.cancel()
            throw error
        }
        return HummingbirdListener(task: task)
    }
}

private struct HummingbirdListener: CacheListening {
    let task: Task<Void, Never>

    func close() async {
        task.cancel()
        await task.value
    }
}

/// Resolves once: nil when the server is listening, or the error that stopped it first.
private actor StartSignal {
    private var outcome: (any Error)??
    private var waiter: CheckedContinuation<(any Error)?, Never>?

    func resolve(_ error: (any Error)?) {
        guard outcome == nil else { return }
        outcome = .some(error)
        waiter?.resume(returning: error)
        waiter = nil
    }

    func wait() async -> (any Error)? {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiter = $0 }
    }
}
