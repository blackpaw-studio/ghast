import Darwin
import Foundation
import Synchronization

/// An IPv4 address configured on a host interface.
struct InterfaceAddress: Equatable, Sendable {
    let name: String
    let address: String
}

protocol InterfaceAddressListing: Sendable {
    func addresses() -> [InterfaceAddress]
}

/// The host's IPv4 interface addresses, from `getifaddrs`.
struct SystemInterfaceAddresses: InterfaceAddressListing {
    func addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { entry in
            guard let socket = entry.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { return nil }
            return InterfaceAddress(name: String(cString: entry.pointee.ifa_name), address: String(cString: host))
        }
    }
}

/// Where a VM reaches the cache.
struct CacheEndpoint: Equatable, Sendable {
    let address: String
    let port: Int

    /// The `ACTIONS_RESULTS_URL` for one VM: its token is the first path segment.
    func resultsURL(vmToken: String) -> URL {
        URL(string: "http://\(address):\(port)/v/\(vmToken)/")!
    }
}

/// Why a VM boots without the cache; `reason` is one line for the runner log.
enum CacheUnavailable: Error, Equatable, Sendable {
    case invalidAddress(String)
    case addressNotLocalBridge(String)
    case bindFailed(address: String, reason: String)

    var reason: String {
        switch self {
        case .invalidAddress(let address): "\(address) isn't an IPv4 address"
        case .addressNotLocalBridge(let address): "\(address) isn't a VM bridge address on this Mac"
        case .bindFailed(let address, let reason): "couldn't listen on \(address): \(reason)"
        }
    }
}

/// One running listener on one address.
protocol CacheListening: Sendable {
    func close() async
}

/// Starts a listener for `responder` on one address and port; returns once it is accepting
/// connections, or throws the bind error.
protocol CacheListenerBinding: Sendable {
    func bind(address: String, port: Int, responder: CacheResponder) async throws -> any CacheListening
}

/// One VM's registration: the token in its results URL and the cache events its calls make.
struct CacheVMRegistration: Sendable {
    let token: String
    let events: AsyncStream<CacheEvent>
}

/// Known VM tokens and their event streams, read from request handlers on any thread.
final class CacheVMRegistry: Sendable {
    private let continuations = Mutex<[String: AsyncStream<CacheEvent>.Continuation]>([:])

    func register(_ token: String) -> AsyncStream<CacheEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CacheEvent.self, bufferingPolicy: .bufferingNewest(256))
        continuations.withLock { $0[token] = continuation }
        return stream
    }

    func unregister(_ token: String) {
        continuations.withLock { $0.removeValue(forKey: token) }?.finish()
    }

    func unregisterAll() {
        continuations.withLock { all in
            defer { all.removeAll() }
            return Array(all.values)
        }.forEach { $0.finish() }
    }

    func contains(_ token: String) -> Bool {
        continuations.withLock { $0[token] != nil }
    }

    func emit(_ event: CacheEvent, for token: String) {
        _ = continuations.withLock { $0[token] }?.yield(event)
    }
}
