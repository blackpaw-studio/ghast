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

    /// A server with one VM registered and listening on 127.0.0.1, at a port that was free a
    /// moment ago.
    private func start() async throws -> (CacheServer, CacheVMRegistration, CacheEndpoint) {
        let randomness = SequentialCacheRandomness()
        randomness.ports = [try RawConnection.freePort()]
        let store = try CacheStore(root: folder.url, clock: FakeClock(), randomness: randomness, writer: FileBlobWriter())
        let server = CacheServer(store: store, verifier: FakeCacheVerifier(), upstream: upstream, randomness: randomness,
                                 interfaces: FakeInterfaces([InterfaceAddress(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0")]),
                                 allowLoopbackForTests: true)
        let registration = server.registerVM()
        return (server, registration, try await server.endpoint(forVM: registration.id, gateway: "127.0.0.1").get())
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
        let (server, registration, endpoint) = try await start()
        let base = endpoint.resultsURL
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

        server.unregisterVM(registration.id)
        var events: [CacheEvent] = []
        for await event in registration.events { events.append(event) }
        #expect(events == [.saved(key: "deps", sizeBytes: 1000), .hit(key: "deps", matchedKey: "deps", sizeBytes: 1000)])
        await server.stop()
    }

    /// actions/toolkit builds each call as `new URL(`/twirp/${service}/${method}`, baseUrl)`
    /// (cacheTwirpClient.ts, artifact-twirp-client.ts): the leading slash drops any path in
    /// ACTIONS_RESULTS_URL, so only its origin reaches the server.
    private func toolkitURL(_ resultsURL: URL, _ service: String, _ method: String) throws -> URL {
        try #require(URL(string: "/twirp/\(service)/\(method)", relativeTo: resultsURL)?.absoluteURL)
    }

    @Test("a client that builds URLs like actions/toolkit saves, restores and reaches the passthrough")
    func toolkitURLs() async throws {
        defer { folder.cleanup() }
        let (server, _, endpoint) = try await start()
        let resultsURL = endpoint.resultsURL
        let cacheService = "github.actions.results.api.v1.CacheService"
        func call(_ method: String, _ json: [String: Any]) async throws -> (status: Int, body: Data) {
            let response = try await send(try toolkitURL(resultsURL, cacheService, method), method: "POST",
                                          headers: ["Authorization": "Bearer writer", "Content-Type": "application/json"],
                                          body: try JSONSerialization.data(withJSONObject: json))
            return (response.status, response.body)
        }
        func json(_ body: Data) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }

        let created = try await call("CreateCacheEntry", ["key": "deps", "version": "v1"])
        #expect(created.status == 200)
        let uploadURL = try #require((try? json(created.body))?["signed_upload_url"] as? String).flatMap(URL.init(string:))
        let put = try await send(try #require(uploadURL), method: "PUT", headers: ["x-ms-blob-type": "BlockBlob"], body: Data([1, 2, 3]))
        #expect(put.status == 201)
        let finalized = try await call("FinalizeCacheEntryUpload", ["key": "deps", "version": "v1", "size_bytes": "3"])
        #expect((try? json(finalized.body))?["ok"] as? Bool == true)
        let got = try await call("GetCacheEntryDownloadURL", ["key": "deps", "version": "v1"])
        let downloadURL = try #require((try? json(got.body))?["signed_download_url"] as? String).flatMap(URL.init(string:))
        #expect(try await send(try #require(downloadURL)).body == Data([1, 2, 3]))

        let artifact = try toolkitURL(resultsURL, "github.actions.results.api.v1.ArtifactService", "CreateArtifact")
        let forwarded = try await send(artifact, method: "POST", headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        #expect(forwarded.status == 200)
        #expect(await upstream.requests.map(\.url.path) == [artifact.path])
        await server.stop()
    }

    @Test("once its VM unregisters, a listener answers 404")
    func unregisteredVM() async throws {
        defer { folder.cleanup() }
        let (server, registration, endpoint) = try await start()
        let artifact = "twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact"

        server.unregisterVM(registration.id)
        let cache = try? await twirp(endpoint.resultsURL, "GetCacheEntryDownloadURL", ["key": "a", "version": "v"])
        let forwarded = try? await send(endpoint.resultsURL.appendingPathComponent(artifact), method: "POST", body: Data("{}".utf8))

        // The listener may already be closed (no answer at all), or answer 404 while it closes.
        #expect(cache.map { $0.status == 404 } ?? true)
        #expect(forwarded.map { $0.status == 404 } ?? true)
        #expect(await upstream.requests.isEmpty)
        await server.stop()
    }

    @Test("non-cache calls at the VM's origin are forwarded with their path")
    func passthrough() async throws {
        defer { folder.cleanup() }
        let (server, _, endpoint) = try await start()
        let artifact = "twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact"

        let forwarded = try await send(endpoint.resultsURL.appendingPathComponent(artifact),
                                       method: "POST", headers: ["Content-Type": "application/json"], body: Data("{}".utf8))

        #expect(forwarded.status == 200)
        #expect(await upstream.requests.map(\.url.path) == ["/" + artifact])
        await server.stop()
    }

    @Test("a Twirp cache call that isn't a POST is refused")
    func twirpNeedsPost() async throws {
        defer { folder.cleanup() }
        let (server, _, endpoint) = try await start()
        let url = endpoint.resultsURL.appendingPathComponent(Self.twirp + "GetCacheEntryDownloadURL")
        let response = try await send(url, headers: ["Authorization": "Bearer writer"])
        #expect(response.status == 404)
        #expect(await upstream.requests.isEmpty)
        await server.stop()
    }
}
