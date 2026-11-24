import Darwin
import Foundation
import Testing
@testable import Ghast

/// Routing over real HTTP on a loopback listener (the test-only bind policy).
@MainActor
@Suite("Cache server routing")
struct CacheServerRoutingTests {
    private let folder = CacheTestFolder()
    private let upstream = FakeUpstream()
    private let session = URLSession(configuration: .ephemeral)
    private static let twirp = "twirp/github.actions.results.api.v1.CacheService/"

    /// A server listening on 127.0.0.1 at a port that was free a moment ago.
    private func start() async throws -> (CacheServer, CacheEndpoint) {
        let randomness = SequentialCacheRandomness()
        randomness.port = try RawConnection.freePort()
        let store = try CacheStore(root: folder.url, clock: FakeClock(), randomness: randomness, writer: FileBlobWriter())
        let server = CacheServer(store: store, verifier: FakeCacheVerifier(), upstream: upstream, randomness: randomness,
                                 interfaces: FakeInterfaces([InterfaceAddress(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0")]),
                                 allowLoopbackForTests: true)
        return (server, try await server.endpoint(forGateway: "127.0.0.1").get())
    }

    private func send(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil)
        async throws -> (status: Int, headers: [AnyHashable: Any], body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, http.allHeaderFields, data)
    }

    private func twirp(_ base: URL, _ method: String, _ json: [String: Any], bearer: String = "writer")
        async throws -> (status: Int, json: [String: Any]) {
        let response = try await send(base.appendingPathComponent(Self.twirp + method), method: "POST",
                                      headers: ["Authorization": "Bearer \(bearer)", "Content-Type": "application/json"],
                                      body: try JSONSerialization.data(withJSONObject: json))
        return (response.status, try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
    }

    @Test("a save and a restore work end to end, with one event per cache call")
    func saveAndRestore() async throws {
        defer { folder.cleanup() }
        let (server, endpoint) = try await start()
        let registration = server.registerVM()
        let base = endpoint.resultsURL(vmToken: registration.token)
        let archive = Data((0 ..< 1000).map { UInt8(truncatingIfNeeded: $0 * 31) })

        let created = try await twirp(base, "CreateCacheEntry", ["key": "deps", "version": "v1"])
        let uploadURLText = try #require(created.json["signed_upload_url"] as? String)
        let uploadURL = try #require(URL(string: uploadURLText))
        #expect(uploadURL.host == "127.0.0.1" && uploadURL.port == endpoint.port)
        let put = try await send(uploadURL, method: "PUT", headers: ["x-ms-blob-type": "BlockBlob"], body: archive)
        #expect(put.status == 201)
        let finalized = try await twirp(base, "FinalizeCacheEntryUpload", ["key": "deps", "version": "v1", "size_bytes": "1000"])
        #expect(finalized.json["ok"] as? Bool == true)

        let got = try await twirp(base, "GetCacheEntryDownloadURL", ["key": "deps", "version": "v1"], bearer: "writer")
        let downloadURLText = try #require(got.json["signed_download_url"] as? String)
        let downloadURL = try #require(URL(string: downloadURLText))
        #expect(try await send(downloadURL).body == archive)
        let ranged = try await send(downloadURL, headers: ["x-ms-range": "bytes=10-19"])
        #expect(ranged.status == 206)
        #expect(ranged.body == archive[10 ..< 20])
        let head = try await send(downloadURL, method: "HEAD")
        #expect(head.headers["Content-Length"] as? String == "1000")

        server.unregisterVM(registration.token)
        var events: [CacheEvent] = []
        for await event in registration.events { events.append(event) }
        #expect(events == [.saved(key: "deps", sizeBytes: 1000), .hit(key: "deps", matchedKey: "deps", sizeBytes: 1000)])
        await server.stop()
    }

    @Test("an unknown or unregistered VM token is 404")
    func unknownToken() async throws {
        defer { folder.cleanup() }
        let (server, endpoint) = try await start()
        let registration = server.registerVM()

        let unknown = try await twirp(endpoint.resultsURL(vmToken: "not-a-token"), "GetCacheEntryDownloadURL",
                                      ["key": "a", "version": "v"])
        server.unregisterVM(registration.token)
        let gone = try await twirp(endpoint.resultsURL(vmToken: registration.token), "GetCacheEntryDownloadURL",
                                   ["key": "a", "version": "v"])

        #expect(unknown.status == 404)
        #expect(gone.status == 404)
        await server.stop()
    }

    @Test("non-cache calls under a VM token are forwarded, and nowhere else")
    func passthroughNeedsToken() async throws {
        defer { folder.cleanup() }
        let (server, endpoint) = try await start()
        let registration = server.registerVM()
        let root = URL(string: "http://127.0.0.1:\(endpoint.port)/")!
        let artifact = "twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact"

        let forwarded = try await send(endpoint.resultsURL(vmToken: registration.token).appendingPathComponent(artifact),
                                       method: "POST", headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        let atRoot = try await send(root.appendingPathComponent(artifact), method: "POST", body: Data("{}".utf8))
        let unknownPath = try await send(root.appendingPathComponent("anything"))

        #expect(forwarded.status == 200)
        #expect(await upstream.requests.map(\.url.path) == ["/" + artifact])
        #expect(atRoot.status == 404)
        #expect(unknownPath.status == 404)
        await server.stop()
    }

    @Test("a Twirp cache call that isn't a POST is refused")
    func twirpNeedsPost() async throws {
        defer { folder.cleanup() }
        let (server, endpoint) = try await start()
        let registration = server.registerVM()
        let url = endpoint.resultsURL(vmToken: registration.token).appendingPathComponent(Self.twirp + "GetCacheEntryDownloadURL")
        let response = try await send(url, headers: ["Authorization": "Bearer writer"])
        #expect(response.status == 404)
        #expect(await upstream.requests.isEmpty)
        await server.stop()
    }
}
