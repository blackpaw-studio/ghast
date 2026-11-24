import Foundation
import Testing
@testable import Ghast

/// The real Hummingbird listener on loopback: who it lets in, before any HTTP is parsed.
@Suite("Cache listener admission")
struct CacheListenerTests {
    private let folder = CacheTestFolder()
    private static let request = Array("GET /nothing HTTP/1.1\r\nHost: x\r\n\r\n".utf8)

    private func makeResponder(port: Int) throws -> CacheResponder {
        let store = try CacheStore(root: folder.url, clock: FakeClock(), randomness: SequentialCacheRandomness(),
                                   writer: FileBlobWriter())
        let router = CacheRouter(twirp: CacheTwirpService(store: store, verifier: FakeCacheVerifier()),
                                 upload: CacheBlobUploadHandler(store: store), download: CacheBlobDownloadHandler(store: store),
                                 passthrough: CachePassthrough(upstream: FakeUpstream()), registry: CacheVMRegistry())
        return CacheResponder(router: router, serverBase: URL(string: "http://127.0.0.1:\(port)/")!)
    }

    private func listen(peers: CacheSubnet) async throws -> (any CacheListening, Int) {
        let port = try RawConnection.freePort()
        let listener = try await HummingbirdListenerBinder().bind(address: "127.0.0.1", port: port, peers: peers,
                                                                  responder: try makeResponder(port: port))
        return (listener, port)
    }

    @Test("a peer outside the bridge subnet is closed without a reply")
    func refusesOutsider() async throws {
        defer { folder.cleanup() }
        let (listener, port) = try await listen(peers: try #require(CacheSubnet(address: "10.0.0.1", netmask: "255.255.255.0")))
        let fd = try RawConnection.open(port: port)
        defer { close(fd) }

        let outcome = await RawConnection.exchange(fd, send: Self.request, waitLimit: .seconds(5))

        #expect(outcome.wasClosed)
        #expect(outcome.received.isEmpty)
        await listener.close()
    }

    @Test("a peer inside the bridge subnet is served")
    func servesInsider() async throws {
        defer { folder.cleanup() }
        let (listener, port) = try await listen(peers: try #require(CacheSubnet(address: "127.0.0.1", netmask: "255.0.0.0")))
        let fd = try RawConnection.open(port: port)
        defer { close(fd) }

        let outcome = await RawConnection.exchange(fd, send: Array("GET /nothing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8),
                                                   waitLimit: .seconds(5))

        #expect(String(decoding: outcome.received, as: UTF8.self).hasPrefix("HTTP/1.1 404"))
        await listener.close()
    }
}
