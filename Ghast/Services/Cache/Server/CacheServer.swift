import Darwin
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import Synchronization

/// The cache's HTTP server. Each VM gets its own port, chosen when it registers (before it
/// boots, so the port can go in its softnet rules), and its own listener on that port, bound on
/// its bridge address once the VM's gateway is known and closed when the VM unregisters. The
/// port tells the server which VM a call comes from; the job's runtime token still authorizes
/// it. Only `bridge*` addresses are ever bound: never a wildcard, loopback or LAN one.
@MainActor
final class CacheServer {
    private let router: CacheRouter
    private let registry: CacheVMRegistry
    private let randomness: any CacheRandomness
    private let interfaces: any InterfaceAddressListing
    private let binder: any CacheListenerBinding
    private let allowsLoopback: Bool
    private var vms: [String: VMListener] = [:]
    /// Listeners being closed, awaited by `stop()`.
    private var closing: [UUID: Task<Void, Never>] = [:]

    /// A registered VM's port and its listener (once bound) or its bind in progress.
    private struct VMListener {
        let port: Int
        var listener: (listener: any CacheListening, address: String, peers: CacheSubnet)?
        var binding: (id: UUID, address: String, task: Task<Result<any CacheListening, CacheUnavailable>, Never>)?
    }

    /// Tries this many random ports for a VM before taking one another VM already holds (its
    /// bind then fails, and that job uses GitHub's cache).
    private static let portAttempts = 32

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
    }

    /// Where each registered VM's listener is bound, as `address:port`.
    var boundEndpoints: [String] {
        vms.values.compactMap { vm in vm.listener.map { "\($0.address):\(vm.port)" } }.sorted()
    }

    /// Registers a VM before it boots: picks its port and opens its event stream, which ends at
    /// `unregisterVM`.
    func registerVM() -> CacheVMRegistration {
        let id = randomness.id128()
        let port = freshPort()
        vms[id] = VMListener(port: port)
        return CacheVMRegistration(id: id, port: port, events: registry.register(id))
    }

    /// Opens the VM's port on `gateway` (a VM bridge address) and returns where the VM reaches
    /// it. A listener that stopped on its own, or is on another address or subnet, is replaced.
    func endpoint(forVM id: String, gateway: String) async -> Result<CacheEndpoint, CacheUnavailable> {
        guard let address = Self.canonicalIPv4(gateway) else { return .failure(.invalidAddress(gateway)) }
        guard let port = vms[id]?.port else { return .failure(.notRegistered) }
        guard let peers = liveBridges()[address] else { return .failure(.addressNotLocalBridge(gateway)) }
        let endpoint = CacheEndpoint(address: address, port: port)
        if let current = vms[id]?.listener {
            if current.address == address, current.peers == peers, current.listener.isRunning { return .success(endpoint) }
            vms[id]?.listener = nil
            close(current.listener)
        }
        // No await from here until a bind is pending or its result is read, so the checks hold.
        if let pending = vms[id]?.binding, pending.address == address {
            return await pending.task.value.map { _ in endpoint }
        }

        let bindID = UUID()
        let task = startBinding(address, port: port, peers: peers, vmID: id)
        vms[id]?.binding = (bindID, address, task)
        let result = await task.value
        guard vms[id]?.binding?.id == bindID else {
            // The VM unregistered (or the server stopped) meanwhile, and that closes this bind.
            return .failure(.notRegistered)
        }
        vms[id]?.binding = nil
        return result.map { listener in
            vms[id]?.listener = (listener, address, peers)
            return endpoint
        }
    }

    /// Ends the VM's events and closes its listener (or its bind in progress).
    func unregisterVM(_ id: String) {
        registry.unregister(id)
        guard let vm = vms.removeValue(forKey: id) else { return }
        vm.listener.map { close($0.listener) }
        vm.binding.map { pending in
            closeWhenBound(pending.task)
        }
    }

    /// Closes every listener and ends every VM's events (app quit).
    func stop() async {
        vms.keys.forEach(unregisterVM)
        registry.unregisterAll()
        for task in closing.values { await task.value }
        closing.removeAll()
    }

    /// A random high port no registered VM holds.
    private func freshPort() -> Int {
        let taken = Set(vms.values.map(\.port))
        var port = randomness.highPort()
        var attempts = 1
        while taken.contains(port), attempts < Self.portAttempts {
            port = randomness.highPort()
            attempts += 1
        }
        return port
    }

    private func close(_ listener: any CacheListening) {
        let id = UUID()
        closing[id] = Task { [weak self] in
            await listener.close()
            self?.closing[id] = nil
        }
    }

    private func closeWhenBound(_ bind: Task<Result<any CacheListening, CacheUnavailable>, Never>) {
        let id = UUID()
        closing[id] = Task { [weak self] in
            if case .success(let listener) = await bind.value { await listener.close() }
            self?.closing[id] = nil
        }
    }

    private func startBinding(_ address: String, port: Int, peers: CacheSubnet, vmID: String)
        -> Task<Result<any CacheListening, CacheUnavailable>, Never> {
        let binder = binder
        let responder = CacheResponder(router: router, serverBase: URL(string: "http://\(address):\(port)/")!, vmID: vmID)
        return Task {
            do {
                return .success(try await binder.bind(address: address, port: port, peers: peers, responder: responder))
            } catch {
                let reason = String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown error"
                return .failure(.bindFailed(address: address, reason: reason))
            }
        }
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

/// Runs one Hummingbird HTTP/1.1 server per VM listener, under `limits`: read deadlines, an
/// idle timeout, and connection caps in all and per peer, shared by every listener this binder
/// starts.
struct HummingbirdListenerBinder: CacheListenerBinding {
    let limits: CacheConnectionLimits
    private let peerLimiter: CachePeerLimiter

    init(limits: CacheConnectionLimits = CacheConnectionLimits()) {
        self.limits = limits
        peerLimiter = CachePeerLimiter(maximumPerPeer: limits.maximumPerPeer, maximumTotal: limits.maximumConnections)
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
