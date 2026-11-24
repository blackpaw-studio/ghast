import Foundation
import Testing
@testable import Ghast

/// Grants by token: "writer" saves to feature and reads feature then main; "reader" only reads.
struct FakeCacheVerifier: CacheTokenVerifying {
    static let repo = CacheRepoID(rawValue: "1468153538")

    func verify(bearer: String) async -> Result<CacheGrant, CacheAuthError> {
        switch bearer {
        case "writer":
            .success(CacheGrant(repo: Self.repo, readScopes: ["refs/heads/feature", "refs/heads/main"], writeScope: "refs/heads/feature"))
        case "main-writer":
            .success(CacheGrant(repo: Self.repo, readScopes: ["refs/heads/main"], writeScope: "refs/heads/main"))
        case "reader":
            .success(CacheGrant(repo: Self.repo, readScopes: ["refs/heads/main"], writeScope: nil))
        default:
            .failure(.badSignature)
        }
    }
}

@Suite("Cache Twirp service")
struct CacheTwirpTests {
    private let folder = CacheTestFolder()
    private let clock = FakeClock()
    private let base = URL(string: "http://192.168.64.1:50000/")!

    private func makeService() throws -> (CacheTwirpService, CacheStore) {
        let store = try CacheStore(root: folder.url, clock: clock, randomness: SequentialCacheRandomness(), writer: FileBlobWriter())
        return (CacheTwirpService(store: store, verifier: FakeCacheVerifier()), store)
    }

    private func call(_ service: CacheTwirpService, _ method: String, _ json: Any, bearer: String? = "writer")
        async throws -> (status: Int, body: [String: Any], event: CacheEvent?) {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try await call(service, method, data: data, bearer: bearer)
    }

    private func call(_ service: CacheTwirpService, _ method: String, data: Data, bearer: String? = "writer")
        async throws -> (status: Int, body: [String: Any], event: CacheEvent?) {
        let (response, event) = await service.handle(method: method, bearer: bearer, body: data, serverBase: base)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any], "body is a JSON object")
        return (response.status, body, event)
    }

    /// Creates an entry for `key` with `bytes` through the service and the store.
    private func save(_ service: CacheTwirpService, _ store: CacheStore, key: String, bearer: String = "writer",
                      bytes: [UInt8] = [1, 2, 3]) async throws {
        let created = try await call(service, "CreateCacheEntry", ["key": key, "version": "v1"], bearer: bearer)
        let urlString = try #require(created.body["signed_upload_url"] as? String)
        let url = try #require(URL(string: urlString))
        try await store.writePart(uploadID: url.lastPathComponent, part: .whole, bytes: bytes)
        _ = try await call(service, "FinalizeCacheEntryUpload",
                           ["key": key, "version": "v1", "size_bytes": String(bytes.count)], bearer: bearer)
    }

    @Test("create, finalize and get follow the captured request shapes")
    func fixtureHappyPath() async throws {
        defer { folder.cleanup() }
        let (service, store) = try makeService()
        let save = try ActionsCacheFixture.records("small-save")
        let restore = try ActionsCacheFixture.records("small-restore")

        let created = try await call(service, "CreateCacheEntry", data: try #require(save[0].jsonBody))
        #expect(created.status == 200)
        #expect(created.body["ok"] as? Bool == true)
        #expect(created.body["message"] as? String == "")
        let uploadString = try #require(created.body["signed_upload_url"] as? String)
        let upload = try #require(URL(string: uploadString))
        #expect(upload.absoluteString.hasPrefix("http://192.168.64.1:50000/devstoreaccount1/upload/"))
        #expect(URLComponents(url: upload, resolvingAgainstBaseURL: false)?.queryItems?.first?.name == "sig")

        let size = save[1].bodyLength
        try await store.writePart(uploadID: upload.lastPathComponent, part: .whole, bytes: [UInt8](repeating: 7, count: size))
        let finalized = try await call(service, "FinalizeCacheEntryUpload", data: try #require(save[2].jsonBody))
        #expect(finalized.body["ok"] as? Bool == true)
        #expect(Int64(try #require(finalized.body["entry_id"] as? String)) != nil)
        #expect(finalized.event == .saved(key: "spike-small-45305005542", sizeBytes: Int64(size)))

        let got = try await call(service, "GetCacheEntryDownloadURL", data: try #require(restore[0].jsonBody))
        #expect(got.body["ok"] as? Bool == true)
        #expect(got.body["matched_key"] as? String == "spike-small-45305005542")
        #expect((got.body["signed_download_url"] as? String)?.hasPrefix("http://192.168.64.1:50000/download/") == true)
        #expect(got.event == .hit(key: "spike-small-45305005542", matchedKey: "spike-small-45305005542", sizeBytes: Int64(size)))
    }

    @Test("a restore-key prefix hit returns the matched key")
    func prefixHit() async throws {
        defer { folder.cleanup() }
        let (service, store) = try makeService()
        try await save(service, store, key: "deps-abc")
        let got = try await call(service, "GetCacheEntryDownloadURL",
                                 ["key": "deps-xyz", "restore_keys": ["deps-"], "version": "v1"])
        #expect(got.body["matched_key"] as? String == "deps-abc")
    }

    @Test("a miss is ok false, not an error")
    func miss() async throws {
        defer { folder.cleanup() }
        let (service, _) = try makeService()
        let got = try await call(service, "GetCacheEntryDownloadURL", ["key": "nothing", "version": "v1"])
        #expect(got.status == 200)
        #expect(got.body["ok"] as? Bool == false)
        #expect(got.event == .miss(key: "nothing"))
    }

    @Test("a duplicate create is ok false")
    func duplicateCreate() async throws {
        defer { folder.cleanup() }
        let (service, _) = try makeService()
        _ = try await call(service, "CreateCacheEntry", ["key": "deps", "version": "v1"])
        let second = try await call(service, "CreateCacheEntry", ["key": "deps", "version": "v1"])
        #expect(second.status == 200)
        #expect(second.body["ok"] as? Bool == false)
    }

    @Test("a token with no write scope can't save")
    func readOnlyToken() async throws {
        defer { folder.cleanup() }
        let (service, _) = try makeService()
        let created = try await call(service, "CreateCacheEntry", ["key": "deps", "version": "v1"], bearer: "reader")
        #expect(created.status == 200)
        #expect(created.body["ok"] as? Bool == false)
    }

    @Test("a restore searches the read scopes in the token's order")
    func scopeOrder() async throws {
        defer { folder.cleanup() }
        let (service, store) = try makeService()
        try await save(service, store, key: "deps", bearer: "main-writer", bytes: [1])
        clock.advance(by: 1)
        try await save(service, store, key: "deps", bearer: "writer", bytes: [1, 2])

        let fromFeature = try await call(service, "GetCacheEntryDownloadURL", ["key": "deps", "version": "v1"])
        let fromMain = try await call(service, "GetCacheEntryDownloadURL", ["key": "deps", "version": "v1"], bearer: "reader")
        #expect(fromFeature.event == .hit(key: "deps", matchedKey: "deps", sizeBytes: 2))
        #expect(fromMain.event == .hit(key: "deps", matchedKey: "deps", sizeBytes: 1))
    }

    @Test("finalize for a size that doesn't match is ok false")
    func finalizeMismatch() async throws {
        defer { folder.cleanup() }
        let (service, store) = try makeService()
        let created = try await call(service, "CreateCacheEntry", ["key": "deps", "version": "v1"])
        let urlString = try #require(created.body["signed_upload_url"] as? String)
        let url = try #require(URL(string: urlString))
        try await store.writePart(uploadID: url.lastPathComponent, part: .whole, bytes: [1])
        let finalized = try await call(service, "FinalizeCacheEntryUpload", ["key": "deps", "version": "v1", "size_bytes": 2])
        #expect(finalized.status == 200)
        #expect(finalized.body["ok"] as? Bool == false)
        #expect(finalized.event == .saveSkipped(key: "deps", reason: "size mismatch (expected 2, got 1)"))
    }

    @Test("no token or a bad token is a 401 Twirp error", arguments: [nil, "forged"] as [String?])
    func unauthenticated(bearer: String?) async throws {
        defer { folder.cleanup() }
        let (service, _) = try makeService()
        let got = try await call(service, "GetCacheEntryDownloadURL", ["key": "a", "version": "v1"], bearer: bearer)
        #expect(got.status == 401)
        #expect(got.body["code"] as? String == "unauthenticated")
    }

    @Test("malformed, oversize and empty-field bodies are 400 Twirp errors")
    func badBodies() async throws {
        defer { folder.cleanup() }
        let (service, _) = try makeService()
        let oversize = Data(#"{"key":"\#(String(repeating: "a", count: 70_000))","version":"v1"}"#.utf8)
        for data in [Data("{".utf8), oversize, Data(#"{"key":"","version":"v1"}"#.utf8)] {
            let got = try await call(service, "CreateCacheEntry", data: data)
            #expect(got.status == 400)
            #expect(got.body["code"] as? String == "malformed")
        }
    }

    @Test("an unknown method is a 404 Twirp error")
    func unknownMethod() async throws {
        defer { folder.cleanup() }
        let (service, _) = try makeService()
        let got = try await call(service, "DeleteCacheEntry", ["key": "a"])
        #expect(got.status == 404)
        #expect(got.body["code"] as? String == "bad_route")
    }
}
