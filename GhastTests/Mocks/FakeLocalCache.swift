import Foundation
@testable import Ghast

/// A cache server a test controls: ports from 50123 up, one per registered VM, a canned
/// endpoint answer, and VM registrations whose events the test can emit.
@MainActor
final class FakeLocalCache: LocalCacheServing {
    static let firstPort = 50123
    var unavailable: CacheUnavailable?
    private(set) var gateways: [String] = []
    private(set) var registered: [String] = []
    private(set) var unregistered: [String] = []
    private(set) var isStopped = false
    private var ports: [String: Int] = [:]
    private var continuations: [String: AsyncStream<CacheEvent>.Continuation] = [:]

    func registerVM() -> CacheVMRegistration {
        let id = "vm-\(registered.count + 1)"
        let port = Self.firstPort + registered.count
        registered.append(id)
        ports[id] = port
        let (stream, continuation) = AsyncStream.makeStream(of: CacheEvent.self)
        continuations[id] = continuation
        return CacheVMRegistration(id: id, port: port, events: stream)
    }

    func endpoint(forVM id: String, gateway: String) async -> Result<CacheEndpoint, CacheUnavailable> {
        gateways.append(gateway)
        if let unavailable { return .failure(unavailable) }
        guard let port = ports[id] else { return .failure(.notRegistered) }
        return .success(CacheEndpoint(address: gateway, port: port))
    }

    func unregisterVM(_ id: String) {
        unregistered.append(id)
        ports[id] = nil
        continuations.removeValue(forKey: id)?.finish()
    }

    func stop() async {
        isStopped = true
    }

    func emit(_ event: CacheEvent, for id: String) {
        continuations[id]?.yield(event)
    }
}
