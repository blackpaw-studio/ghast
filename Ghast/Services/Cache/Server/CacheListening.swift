import Darwin
import Foundation
import Synchronization

/// An IPv4 address configured on a host interface.
struct InterfaceAddress: Equatable, Sendable {
    let name: String
    let address: String
    let netmask: String
}

/// The IPv4 subnet of a VM bridge: the peers a listener on that bridge accepts. macOS uses
/// the weak host model, so a LAN host can route to a bridge address through the Mac's LAN
/// address; checking the peer against the bridge's subnet keeps it out (a spoofed source
/// can't finish the TCP handshake, because the replies go to the bridge).
struct CacheSubnet: Equatable, Sendable {
    let address: String
    let netmask: String
    private let network: UInt32
    private let mask: UInt32

    /// Nil unless both are canonical IPv4 addresses and the netmask is contiguous and non-zero.
    init?(address: String, netmask: String) {
        guard let value = Self.ipv4(address), let mask = Self.ipv4(netmask), mask != 0 else { return nil }
        let hostBits = ~mask
        guard hostBits & (hostBits &+ 1) == 0 else { return nil }
        self.address = address
        self.netmask = netmask
        self.mask = mask
        network = value & mask
    }

    /// True for a host address inside the subnet. The network and broadcast addresses are
    /// never peers (except on /31 and /32, which have none).
    func contains(_ remote: String) -> Bool {
        guard let value = Self.ipv4(remote), value & mask == network else { return false }
        let hostBits = ~mask
        guard hostBits > 1 else { return true }
        return value != network && value != network | hostBits
    }

    /// A canonical dotted-quad IPv4 address as a host-order number, else nil.
    static func ipv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1, format(address) == text else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func format(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
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
            guard let socket = entry.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask,
                  let address = Self.ipv4(socket), let netmask = Self.ipv4(mask) else { return nil }
            return InterfaceAddress(name: String(cString: entry.pointee.ifa_name), address: address, netmask: netmask)
        }
    }
}

extension SystemInterfaceAddresses {
    private static func ipv4(_ socket: UnsafeMutablePointer<sockaddr>) -> String? {
        socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { CacheSubnet.format($0.pointee.sin_addr) }
    }
}

/// Where a VM reaches the cache: its own port on its bridge address.
struct CacheEndpoint: Equatable, Sendable {
    let address: String
    let port: Int

    /// The VM's `ACTIONS_RESULTS_URL`: the origin alone. actions/toolkit resolves every call
    /// as `new URL("/twirp/…", base)`, which drops any path in the base, so the port (not a
    /// path) is what tells the server which VM is calling.
    var resultsURL: URL { URL(string: "http://\(address):\(port)/")! }
}

/// Why a VM boots without the cache; `reason` is one line for the runner log.
enum CacheUnavailable: Error, Equatable, Sendable {
    case invalidAddress(String)
    case addressNotLocalBridge(String)
    case bindFailed(address: String, reason: String)
    case notRegistered

    var reason: String {
        switch self {
        case .invalidAddress(let address): "\(address) isn't an IPv4 address"
        case .addressNotLocalBridge(let address): "\(address) isn't a VM bridge address on this Mac"
        case .bindFailed(let address, let reason): "couldn't listen on \(address): \(reason)"
        case .notRegistered: "the VM's cache registration has ended"
        }
    }
}

/// One running listener on one address.
protocol CacheListening: Sendable {
    /// False once the listener has stopped on its own (or been closed).
    var isRunning: Bool { get }
    func close() async
}

/// Starts a listener for `responder` on one address and port; returns once it is accepting
/// connections, or throws the bind error.
protocol CacheListenerBinding: Sendable {
    /// Starts a listener that closes every connection whose peer isn't in `peers`.
    func bind(address: String, port: Int, peers: CacheSubnet, responder: CacheResponder) async throws -> any CacheListening
}

/// One VM's registration: its own port (in its softnet rules before boot, and its listener's
/// port once its gateway is known) and the cache events its calls make.
struct CacheVMRegistration: Sendable {
    let id: String
    let port: Int
    let events: AsyncStream<CacheEvent>
}

/// Registered VMs and their event streams, read from request handlers on any thread.
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
