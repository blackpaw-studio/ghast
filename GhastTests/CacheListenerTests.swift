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

    private static let loopbackPeers = CacheSubnet(address: "127.0.0.1", netmask: "255.0.0.0")!
    /// Short deadlines so the tests wait only as long as the behaviour needs.
    private static let quick = CacheConnectionLimits(headerTimeout: .milliseconds(150), bodyIdleTimeout: .milliseconds(150),
                                                     bodyTimeout: .seconds(30), idleTimeout: .seconds(30),
                                                     maximumConnections: 64, maximumPerPeer: 1)

    private func listen(peers: CacheSubnet = loopbackPeers, limits: CacheConnectionLimits = CacheConnectionLimits())
        async throws -> (any CacheListening, Int) {
        let port = try RawConnection.freePort()
        let listener = try await HummingbirdListenerBinder(limits: limits).bind(
            address: "127.0.0.1", port: port, peers: peers, responder: try makeResponder(port: port))
        return (listener, port)
    }

    @Test("a connection that sends nothing, or only part of its headers, is closed at the header deadline",
          arguments: ["", "GET /nothing HTTP/1.1\r\nHost: x\r\n"])
    func headerDeadline(partial: String) async throws {
        defer { folder.cleanup() }
        let (listener, port) = try await listen(limits: Self.quick)
        let fd = try RawConnection.open(port: port)
        defer { close(fd) }

        let outcome = await RawConnection.exchange(fd, send: Array(partial.utf8), waitLimit: .seconds(5))

        #expect(outcome.wasClosed)
        #expect(outcome.received.isEmpty)
        await listener.close()
    }

    @Test("a request body that stalls is closed at the body idle deadline")
    func bodyIdleDeadline() async throws {
        defer { folder.cleanup() }
        let (listener, port) = try await listen(limits: Self.quick)
        let fd = try RawConnection.open(port: port)
        defer { close(fd) }
        let request = "PUT /devstoreaccount1/upload/x?sig=y HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nab"

        let outcome = await RawConnection.exchange(fd, send: Array(request.utf8), waitLimit: .seconds(5))

        #expect(outcome.wasClosed)
        await listener.close()
    }

    @Test("one peer can't hold more than its share of connections, and the listener keeps serving")
    func perPeerCap() async throws {
        defer { folder.cleanup() }
        var limits = CacheConnectionLimits()
        limits.maximumPerPeer = 1
        let (listener, port) = try await listen(limits: limits)
        // Connections are accepted in order, so the first one holds the peer's only slot.
        let held = try RawConnection.open(port: port)
        let second = try RawConnection.open(port: port)
        let refused = await RawConnection.exchange(second, send: Self.request, waitLimit: .seconds(5))
        close(second)
        close(held)
        // The slot comes back once the server sees the close; retry until it has (bounded).
        var served = RawConnection.Outcome(received: [], wasClosed: true)
        for _ in 0 ..< 100 where served.received.isEmpty {
            let fd = try RawConnection.open(port: port)
            served = await RawConnection.exchange(fd, send: Array("GET /nothing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8),
                                                  waitLimit: .seconds(5))
            close(fd)
        }

        #expect(refused.wasClosed && refused.received.isEmpty)
        #expect(String(decoding: served.received, as: UTF8.self).hasPrefix("HTTP/1.1 404"))
        await listener.close()
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
