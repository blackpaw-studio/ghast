import Foundation
import Testing
@testable import Ghast

@Suite("Cache blob upload")
struct CacheBlobUploadTests {
    private let folder = CacheTestFolder()
    private let repo = CacheRepoID(rawValue: "1")
    private let scope = "refs/heads/main"

    private func makeStore() throws -> CacheStore {
        try CacheStore(root: folder.url, clock: FakeClock(), randomness: SequentialCacheRandomness(), writer: FileBlobWriter())
    }

    private func put(_ handler: CacheBlobUploadHandler, _ id: String, sig: String?, _ extra: [URLQueryItem] = [],
                     headers: [String: String] = [:], bytes: [UInt8], chunk: Int = 4096) async -> BlobResponse {
        let query = (sig.map { [URLQueryItem(name: "sig", value: $0)] } ?? []) + extra
        var headers = headers
        headers["content-length"] = headers["content-length"] ?? String(bytes.count)
        return await handler.handle(method: "PUT", uploadID: id, query: query, headers: headers,
                                    body: Self.chunks(bytes, size: chunk))
    }

    private static func chunks(_ bytes: [UInt8], size: Int) -> AsyncStream<ArraySlice<UInt8>> {
        AsyncStream { continuation in
            stride(from: 0, to: bytes.count, by: max(size, 1)).forEach {
                continuation.yield(bytes[$0 ..< min($0 + size, bytes.count)])
            }
            continuation.finish()
        }
    }

    private func storedBlob(_ store: CacheStore, key: String, size: Int) async throws -> [UInt8] {
        let entry = try await store.finalize(repo: repo, scope: scope, key: key, version: "v", sizeBytes: Int64(size))
        let url = try #require(await store.blobURL(downloadID: entry.downloadID))
        return [UInt8](try Data(contentsOf: url))
    }

    @Test("a single-shot PUT stores the archive")
    func singleShot() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let handler = CacheBlobUploadHandler(store: store)
        let record = try ActionsCacheFixture.records("small-save")[1]
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "small", version: "v"))
        let bytes = (0 ..< record.bodyLength / 64).map { UInt8(truncatingIfNeeded: $0 * 7) }

        let response = await put(handler, reservation.uploadID, sig: reservation.signature,
                                 record.query.filter { $0.0 != "sig" }.map { URLQueryItem(name: $0.0, value: $0.1) },
                                 headers: record.headers.filter { $0.key != "content-length" }, bytes: bytes)

        #expect(response.status == 201)
        #expect(response.headers["x-ms-request-id"] != nil)
        #expect(try await storedBlob(store, key: "small", size: bytes.count) == bytes)
    }

    @Test("blocks arriving out of order are committed in block-list order")
    func blocksReplay() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let handler = CacheBlobUploadHandler(store: store)
        let records = try ActionsCacheFixture.records("large-save").filter { $0.method == "PUT" }
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "large", version: "v"))
        var blockBytes: [String: [UInt8]] = [:]

        for (index, record) in records.enumerated() {
            let query = record.query.filter { $0.0 != "sig" }.map { URLQueryItem(name: $0.0, value: $0.1) }
            let headers = record.headers.filter { $0.key != "content-length" }
            if let id = record.queryValue("blockid") {
                let bytes = [UInt8](repeating: UInt8(index), count: max(record.bodyLength / 65_536, 1))
                blockBytes[id] = bytes
                let response = await put(handler, reservation.uploadID, sig: reservation.signature, query, headers: headers, bytes: bytes)
                #expect(response.status == 201)
            } else {
                let xml = try #require(record.body as? String)
                let response = await put(handler, reservation.uploadID, sig: reservation.signature, query, headers: headers,
                                         bytes: Array(xml.utf8), chunk: 50)
                #expect(response.status == 201)
                let order = Self.latestIDs(xml)
                #expect(order.count == blockBytes.count)
                let expected = order.flatMap { blockBytes[$0] ?? [] }
                #expect(try await storedBlob(store, key: "large", size: expected.count) == expected)
            }
        }
    }

    private static func latestIDs(_ xml: String) -> [String] {
        xml.components(separatedBy: "<Latest>").dropFirst().compactMap { $0.components(separatedBy: "</Latest>").first }
    }

    @Test("a wrong or missing sig is 403", arguments: ["sig-x", "sig-10", nil] as [String?])
    func badSig(sig: String?) async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "k", version: "v"))
        let response = await put(CacheBlobUploadHandler(store: store), reservation.uploadID, sig: sig,
                                 headers: ["x-ms-blob-type": "BlockBlob"], bytes: [1])
        #expect(response.status == 403)
        #expect(await store.pendingUpload(reservation.uploadID)?.hasWhole == false)
    }

    @Test("an unknown upload is 404", arguments: ["id-99", "../id-1", ""])
    func unknownUpload(id: String) async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        _ = try await store.reserve(repo: repo, scope: scope, key: "k", version: "v")
        let response = await put(CacheBlobUploadHandler(store: store), id, sig: "sig-1",
                                 headers: ["x-ms-blob-type": "BlockBlob"], bytes: [1])
        #expect(response.status == 404)
    }

    @Test("a block list naming a block that never arrived fails")
    func missingBlock() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let handler = CacheBlobUploadHandler(store: store)
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "k", version: "v"))
        let one = Data("block-1".utf8).base64EncodedString(), two = Data("block-2".utf8).base64EncodedString()
        _ = await put(handler, reservation.uploadID, sig: reservation.signature,
                      [URLQueryItem(name: "comp", value: "block"), URLQueryItem(name: "blockid", value: one)], bytes: [1])
        let xml = "<?xml version=\"1.0\"?><BlockList><Latest>\(one)</Latest><Latest>\(two)</Latest></BlockList>"
        let response = await put(handler, reservation.uploadID, sig: reservation.signature,
                                 [URLQueryItem(name: "comp", value: "blocklist")], bytes: Array(xml.utf8))
        #expect(response.status == 400)
        #expect(await store.pendingUpload(reservation.uploadID)?.hasWhole == false)
    }

    @Test("block IDs never reach a path, and bad ones are refused")
    func hostileBlockIDs() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let handler = CacheBlobUploadHandler(store: store)
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "k", version: "v"))
        let block = { (id: String) in
            await put(handler, reservation.uploadID, sig: reservation.signature,
                      [URLQueryItem(name: "comp", value: "block"), URLQueryItem(name: "blockid", value: id)], bytes: [1])
        }

        let traversal = Data("../../../escape".utf8).base64EncodedString()
        #expect(await block(traversal).status == 201)
        #expect(await block("../../x").status == 400)
        #expect(await block("").status == 400)
        #expect(await block(Data(repeating: 65, count: 65).base64EncodedString()).status == 400)
        #expect(folder.files().allSatisfy { $0.hasPrefix("uploads/\(reservation.uploadID)/block-") || $0 == "index.json" })
    }

    @Test("a block list with a DOCTYPE or entity is refused", arguments: [
        #"<?xml version="1.0"?><!DOCTYPE BlockList [<!ENTITY x "QQ==">]><BlockList><Latest>&x;</Latest></BlockList>"#,
        #"<?xml version="1.0"?><!DOCTYPE BlockList SYSTEM "file:///etc/passwd"><BlockList></BlockList>"#,
        #"<BlockList><Latest>QQ==</Latest>"#,
        #"<Other><Latest>QQ==</Latest></Other>"#,
    ])
    func hostileXML(xml: String) async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let handler = CacheBlobUploadHandler(store: store)
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "k", version: "v"))
        _ = await put(handler, reservation.uploadID, sig: reservation.signature,
                      [URLQueryItem(name: "comp", value: "block"), URLQueryItem(name: "blockid", value: "QQ==")], bytes: [1])
        let response = await put(handler, reservation.uploadID, sig: reservation.signature,
                                 [URLQueryItem(name: "comp", value: "blocklist")], bytes: Array(xml.utf8))
        #expect(response.status == 400)
        #expect(await store.pendingUpload(reservation.uploadID)?.hasWhole == false)
    }

    @Test("a body shorter than its Content-Length leaves the part incomplete")
    func shortBody() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "k", version: "v"))
        let response = await put(CacheBlobUploadHandler(store: store), reservation.uploadID, sig: reservation.signature,
                                 headers: ["x-ms-blob-type": "BlockBlob", "content-length": "10"], bytes: [1, 2, 3])
        #expect(response.status == 400)
        #expect(await store.pendingUpload(reservation.uploadID)?.hasWhole == false)
    }

    @Test("block count and block-list size are capped")
    func caps() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let handler = CacheBlobUploadHandler(store: store, limits: .init(maximumBlocks: 1, maximumBlockListBytes: 64))
        let reservation = try #require(try await store.reserve(repo: repo, scope: scope, key: "k", version: "v"))
        let block = { (id: String) in
            await put(handler, reservation.uploadID, sig: reservation.signature,
                      [URLQueryItem(name: "comp", value: "block"), URLQueryItem(name: "blockid", value: id)], bytes: [1])
        }
        #expect(await block("QQ==").status == 201)
        #expect(await block("Qg==").status == 400)
        let xml = "<BlockList>" + String(repeating: "<Latest>QQ==</Latest>", count: 4) + "</BlockList>"
        let response = await put(handler, reservation.uploadID, sig: reservation.signature,
                                 [URLQueryItem(name: "comp", value: "blocklist")], bytes: Array(xml.utf8))
        #expect(response.status == 413)
    }
}
