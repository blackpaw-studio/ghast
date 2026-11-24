import Darwin
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import Synchronization

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
    private var listeners: [String: (listener: any CacheListening, peers: CacheSubnet)] = [:]
    /// Binds under way, one per address. Only the call that started one installs its listener.
    private var binding: [String: (id: UUID, task: Task<Result<any CacheListening, CacheUnavailable>, Never>)] = [:]

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
    /// VM reaches it. Closes listeners whose address has gone, or that stopped on their own, first.
    func endpoint(forGateway gateway: String) async -> Result<CacheEndpoint, CacheUnavailable> {
        guard let address = Self.canonicalIPv4(gateway) else { return .failure(.invalidAddress(gateway)) }
        let live = liveBridges()
        await closeListeners(notMatching: live)
        guard let peers = live[address] else { return .failure(.addressNotLocalBridge(gateway)) }
        let endpoint = CacheEndpoint(address: address, port: port)
        if let entry = listeners[address], !entry.listener.isRunning {
            listeners[address] = nil
            await entry.listener.close()
        }
        // No await from here until a bind is pending or its result is read, so the checks hold.
        if listeners[address] != nil { return .success(endpoint) }
        if let pending = binding[address] {
            return await pending.task.value.map { _ in endpoint }
        }

        let id = UUID()
        let task = startBinding(address, peers: peers)
        binding[address] = (id, task)
        let result = await task.value
        guard binding[address]?.id == id else {
            // `stop()` took this bind meanwhile and closed its listener.
            return .failure(.bindFailed(address: address, reason: "the cache server stopped"))
        }
        binding[address] = nil
        return result.map { listener in
            listeners[address] = (listener, peers)
            return endpoint
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
        for (_, task) in pending {
            if case .success(let listener) = await task.value { await listener.close() }
        }
        await closeListeners(notMatching: [:])
    }

    private func startBinding(_ address: String, peers: CacheSubnet) -> Task<Result<any CacheListening, CacheUnavailable>, Never> {
        let binder = binder, port = port
        let responder = CacheResponder(router: router, serverBase: URL(string: "http://\(address):\(port)/")!)
        return Task {
            do {
                return .success(try await binder.bind(address: address, port: port, peers: peers, responder: responder))
            } catch {
                let reason = String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown error"
                return .failure(.bindFailed(address: address, reason: reason))
            }
        }
    }

    /// Closes listeners whose address is gone or whose bridge now has another subnet.
    private func closeListeners(notMatching live: [String: CacheSubnet]) async {
        let gone = listeners.filter { live[$0.key] != $0.value.peers }
        gone.keys.forEach { listeners.removeValue(forKey: $0) }
        for entry in gone.values { await entry.listener.close() }
    }

    /// Bindable bridge addresses and their subnets.
    private func liveBridges() -> [String: CacheSubnet] {
        let pairs = interfaces.addresses().filter(isBindable).compactMap { interface in
            CacheSubnet(address: interface.address, netmask: interface.netmask).map { (interface.address, $0) }
        }
        return Dictionary(pairs) { first, _ in first }
    }

    private func isBindable(_ interface: InterfaceAddress) -> Bool {
        guard Self.canonicalIPv4(interface.address) != nil, interface.address != "0.0.0.0" else { return false }
        if interface.name.hasPrefix("bridge") { return true }
        return allowsLoopback && interface.name == "lo0" && interface.address.hasPrefix("127.")
    }

    /// `text` when it is a dotted-quad IPv4 address written canonically, else nil.
    static func canonicalIPv4(_ text: String) -> String? {
        CacheSubnet.ipv4(text) == nil ? nil : text
    }
}

/// Runs one Hummingbird HTTP/1.1 server per address, capped at 64 connections.
/// Runs one Hummingbird HTTP/1.1 server per address, under `limits`: read deadlines, an idle
/// timeout, and connection caps in all and per peer (shared by this binder's listeners).
struct HummingbirdListenerBinder: CacheListenerBinding {
    let limits: CacheConnectionLimits
    private let peerLimiter: CachePeerLimiter

    init(limits: CacheConnectionLimits = CacheConnectionLimits()) {
        self.limits = limits
        peerLimiter = CachePeerLimiter(maximumPerPeer: limits.maximumPerPeer)
    }

    func bind(address: String, port: Int, peers: CacheSubnet, responder: CacheResponder) async throws -> any CacheListening {
        let started = StartSignal()
        var logger = Logger(label: "net.evancoleman.ghast.cache")
        logger.logLevel = .error
        let limits = limits, peerLimiter = peerLimiter
        let server = HTTPServerBuilder { respond in
            let configuration = HTTP1Channel.Configuration(
                additionalChannelHandlers: [CacheDeadlineHandler(limits: limits)],
                idleTimeout: .nanoseconds(Int64(limits.idleTimeout.components.seconds) * 1_000_000_000))
            return AdmittingHTTP1Channel(inner: HTTP1Channel(responder: respond, configuration: configuration), peers: peers,
                                         peerLimiter: peerLimiter)
        }
        let app = Application(
            responder: responder,
            server: server,
            configuration: .init(address: .hostname(address, port: port),
                                 availableConnectionsDelegate: MaximumAvailableConnections(limits.maximumConnections)),
            onServerRunning: { _ in await started.resolve(nil) },
            logger: logger)
        let running = RunningFlag()
        let task = Task {
            defer { running.stop() }
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
        return HummingbirdListener(task: task, running: running)
    }
}

/// HTTP/1.1, but a connection from outside `peers`, or from a peer already at its connection
/// limit, is closed as soon as it is accepted, before any byte of it is read.
private struct AdmittingHTTP1Channel: ServerChildChannel {
    typealias Value = HTTP1Channel.Value
    let inner: HTTP1Channel
    let peers: CacheSubnet
    let peerLimiter: CachePeerLimiter

    func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<Value> {
        guard let remote = channel.remoteAddress?.ipAddress, peers.contains(remote), peerLimiter.acquire(remote) else {
            channel.close(mode: .all, promise: nil)
            return channel.eventLoop.makeFailedFuture(CacheConnectionRefused())
        }
        channel.closeFuture.whenComplete { _ in peerLimiter.release(remote) }
        return inner.setup(channel: channel, logger: logger)
    }

    func handle(value: Value, logger: Logger) async {
        await inner.handle(value: value, logger: logger)
    }
}

private struct CacheConnectionRefused: Error {}

private struct HummingbirdListener: CacheListening {
    let task: Task<Void, Never>
    let running: RunningFlag

    var isRunning: Bool { running.value }

    func close() async {
        task.cancel()
        await task.value
    }
}

/// Whether a listener's server is still running; cleared when its run ends for any reason.
private final class RunningFlag: Sendable {
    private let state = Mutex(true)
    var value: Bool { state.withLock { $0 } }
    func stop() { state.withLock { $0 = false } }
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
