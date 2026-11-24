import Foundation
@testable import Ghast

/// A cache server a test controls: a fixed port, a canned endpoint answer, and VM
/// registrations whose events the test can emit.
@MainActor
final class FakeLocalCache: LocalCacheServing {
    let port = 50123
    var unavailable: CacheUnavailable?
    private(set) var gateways: [String] = []
    private(set) var registered: [String] = []
    private(set) var unregistered: [String] = []
    private(set) var isStopped = false
    private var continuations: [String: AsyncStream<CacheEvent>.Continuation] = [:]

    func endpoint(forGateway gateway: String) async -> Result<CacheEndpoint, CacheUnavailable> {
        gateways.append(gateway)
        if let unavailable { return .failure(unavailable) }
        return .success(CacheEndpoint(address: gateway, port: port))
    }

    func registerVM() -> CacheVMRegistration {
        let token = "tok-\(registered.count + 1)"
        registered.append(token)
        let (stream, continuation) = AsyncStream.makeStream(of: CacheEvent.self)
        continuations[token] = continuation
        return CacheVMRegistration(token: token, events: stream)
    }

    func unregisterVM(_ token: String) {
        unregistered.append(token)
        continuations.removeValue(forKey: token)?.finish()
    }

    func stop() async {
        isStopped = true
    }

    func emit(_ event: CacheEvent, for token: String) {
        continuations[token]?.yield(event)
    }
}
