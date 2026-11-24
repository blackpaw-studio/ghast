import Foundation
import Testing
@testable import Ghast

@Suite("Cache blob download")
struct CacheBlobDownloadTests {
    private let folder = CacheTestFolder()
    private let bytes = (0 ..< 10).map { UInt8($0) }

    /// A store holding one 10-byte entry; returns the handler and the entry's download ID.
    private func makeHandler() async throws -> (CacheBlobDownloadHandler, String) {
        let store = try CacheStore(root: folder.url, clock: FakeClock(), randomness: SequentialCacheRandomness(),
                                   writer: FileBlobWriter())
        let repo = CacheRepoID(rawValue: "1")
        let reservation = try #require(try await store.reserve(repo: repo, scope: "s", key: "k", version: "v"))
        try await store.writePart(uploadID: reservation.uploadID, part: .whole, bytes: bytes)
        let entry = try await store.finalize(repo: repo, scope: "s", key: "k", version: "v", sizeBytes: Int64(bytes.count))
        return (CacheBlobDownloadHandler(store: store), entry.downloadID)
    }

    private func body(_ response: BlobDownloadResponse) async throws -> [UInt8] {
        var collected: [UInt8] = []
        for try await chunk in try #require(response.body).chunks(size: 3) { collected += chunk }
        return collected
    }

    @Test("a plain GET returns the whole blob", arguments: ["small-restore", "large-restore", "prefix-restore"])
    func fullGet(fixture: String) async throws {
        defer { folder.cleanup() }
        let (handler, id) = try await makeHandler()
        let record = try #require(try ActionsCacheFixture.records(fixture).first { $0.method == "GET" })

        let response = await handler.handle(method: record.method, downloadID: id, headers: record.headers)

        #expect(response.status == record.status)
        #expect(response.headers["accept-ranges"] == "bytes")
        #expect(response.headers["content-length"] == "10")
        #expect(try await body(response) == bytes)
    }

    @Test("HEAD has the headers and no body")
    func head() async throws {
        defer { folder.cleanup() }
        let (handler, id) = try await makeHandler()
        let response = await handler.handle(method: "HEAD", downloadID: id, headers: [:])
        #expect(response.status == 200)
        #expect(response.headers["content-length"] == "10")
        #expect(response.body == nil)
    }

    @Test("a single range is served as 206", arguments: [
        ("bytes=0-", 0, 9), ("bytes=2-5", 2, 5), ("bytes=-3", 7, 9), ("bytes=4-", 4, 9), ("bytes=8-999", 8, 9),
        ("bytes=-50", 0, 9),
    ])
    func ranges(range: String, first: Int, last: Int) async throws {
        defer { folder.cleanup() }
        let (handler, id) = try await makeHandler()
        let response = await handler.handle(method: "GET", downloadID: id, headers: ["range": range])
        #expect(response.status == 206)
        #expect(response.headers["content-range"] == "bytes \(first)-\(last)/10")
        #expect(response.headers["content-length"] == String(last - first + 1))
        #expect(try await body(response) == Array(bytes[first ... last]))
    }

    @Test("x-ms-range wins over Range")
    func msRangeWins() async throws {
        defer { folder.cleanup() }
        let (handler, id) = try await makeHandler()
        let response = await handler.handle(method: "GET", downloadID: id, headers: ["range": "bytes=0-0", "x-ms-range": "bytes=1-2"])
        #expect(response.headers["content-range"] == "bytes 1-2/10")
        #expect(try await body(response) == [1, 2])
    }

    @Test("an unsatisfiable, multiple or malformed range is 416",
          arguments: ["bytes=10-", "bytes=10-20", "bytes=0-1,3-4", "bytes=-0", "bytes=5-2", "items=0-1", "bytes=a-b"])
    func unsatisfiable(range: String) async throws {
        defer { folder.cleanup() }
        let (handler, id) = try await makeHandler()
        let response = await handler.handle(method: "GET", downloadID: id, headers: ["x-ms-range": range])
        #expect(response.status == 416)
        #expect(response.headers["content-range"] == "bytes */10")
        #expect(response.body == nil)
    }

    @Test("an unknown download is 404", arguments: ["nope", "../index.json", ""])
    func unknown(id: String) async throws {
        defer { folder.cleanup() }
        let (handler, _) = try await makeHandler()
        let response = await handler.handle(method: "GET", downloadID: id, headers: [:])
        #expect(response.status == 404)
        #expect(response.body == nil)
    }

    @Test("other methods are refused")
    func otherMethods() async throws {
        defer { folder.cleanup() }
        let (handler, id) = try await makeHandler()
        #expect(await handler.handle(method: "PUT", downloadID: id, headers: [:]).status == 405)
    }
}
