import Foundation
import Testing
@testable import Ghast

/// Pending uploads share one byte budget (the cache cap), so neither a block list nor two
/// uploads together can write more than the cap to disk.
@Suite("Cache upload budget")
struct CacheBudgetTests {
    private let folder = CacheTestFolder()
    private let repo = CacheRepoID(rawValue: "1")

    private func makeStore(cap: Int64) throws -> CacheStore {
        try CacheStore(root: folder.url, clock: FakeClock(), randomness: SequentialCacheRandomness(),
                       writer: FileBlobWriter(), capBytes: cap)
    }

    private func reserve(_ store: CacheStore, _ key: String) async throws -> CacheReservation {
        try #require(try await store.reserve(repo: repo, scope: "s", key: key, version: "v"))
    }

    private func block(_ id: String) -> CacheUploadPart { .block(id: Data(id.utf8).base64EncodedString()) }
    private func blockID(_ id: String) -> String { Data(id.utf8).base64EncodedString() }

    /// Sizes of every file under the cache folder.
    private func fileSizes() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: folder.files().map { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.url.appendingPathComponent(name).path)[.size]
                as? Int) ?? 0
            return (name, size)
        })
    }

    @Test("a block list naming one block many times is refused, and nothing grows past the cap")
    func duplicateBlocks() async throws {
        defer { folder.cleanup() }
        let store = try makeStore(cap: 4)
        let reservation = try await reserve(store, "k")
        let handler = CacheBlobUploadHandler(store: store)
        let blockQuery = [URLQueryItem(name: "sig", value: reservation.signature), URLQueryItem(name: "comp", value: "block"),
                          URLQueryItem(name: "blockid", value: blockID("a"))]
        _ = await handler.handle(method: "PUT", uploadID: reservation.uploadID, query: blockQuery, headers: [:],
                                 body: AsyncStream<[UInt8]> { $0.yield([1, 2, 3, 4]); $0.finish() })
        let xml = "<BlockList>" + String(repeating: "<Latest>\(blockID("a"))</Latest>", count: 10) + "</BlockList>"
        let listQuery = [URLQueryItem(name: "sig", value: reservation.signature), URLQueryItem(name: "comp", value: "blocklist")]

        let response = await handler.handle(method: "PUT", uploadID: reservation.uploadID, query: listQuery, headers: [:],
                                            body: AsyncStream<[UInt8]> { $0.yield(Array(xml.utf8)); $0.finish() })

        #expect(response.status == 400)
        #expect(fileSizes().values.allSatisfy { $0 <= 4 || $0 > 1000 })  // index.json aside, nothing over 4 bytes
        #expect(fileSizes().filter { $0.key.hasPrefix("uploads/") }.values.allSatisfy { $0 <= 4 })
        await #expect(throws: CacheStoreError.duplicateBlock(id: blockID("a"))) {
            try await store.commitBlocks(uploadID: reservation.uploadID, order: [blockID("a"), blockID("a")])
        }
    }

    @Test("a commit larger than the cap is refused before anything is copied")
    func projectedOverCap() async throws {
        defer { folder.cleanup() }
        let store = try makeStore(cap: 10)
        let reservation = try await reserve(store, "k")
        try await store.writePart(uploadID: reservation.uploadID, part: block("a"), bytes: [UInt8](repeating: 1, count: 6))
        try await store.writePart(uploadID: reservation.uploadID, part: block("b"), bytes: [UInt8](repeating: 2, count: 4))
        try await store.setCapBytes(8)

        await #expect(throws: CacheStoreError.tooLarge(sizeBytes: 10, capBytes: 8)) {
            try await store.commitBlocks(uploadID: reservation.uploadID, order: [blockID("a"), blockID("b")])
        }
        #expect(!folder.files().contains { $0.hasSuffix("/archive") })
    }

    @Test("two uploads together can't write more than the cap")
    func sharedBudget() async throws {
        defer { folder.cleanup() }
        let store = try makeStore(cap: 10)
        let first = try await reserve(store, "a"), second = try await reserve(store, "b")
        try await store.writePart(uploadID: first.uploadID, part: .whole, bytes: [UInt8](repeating: 1, count: 6))

        await #expect(throws: CacheStoreError.self) {
            try await store.writePart(uploadID: second.uploadID, part: .whole, bytes: [UInt8](repeating: 2, count: 6))
        }
        let refused = await CacheBlobUploadHandler(store: store).handle(
            method: "PUT", uploadID: second.uploadID, query: [URLQueryItem(name: "sig", value: second.signature)],
            headers: ["x-ms-blob-type": "BlockBlob"], body: AsyncStream<[UInt8]> { $0.yield([UInt8](repeating: 2, count: 6)); $0.finish() })
        #expect(refused.status == 413)

        _ = try await store.finalize(repo: repo, scope: "s", key: "a", version: "v", sizeBytes: 6)
        try await store.writePart(uploadID: second.uploadID, part: .whole, bytes: [UInt8](repeating: 2, count: 6))
    }

    @Test("an abandoned part gives back its bytes and its file")
    func abandonedPart() async throws {
        defer { folder.cleanup() }
        let store = try makeStore(cap: 10)
        let first = try await reserve(store, "a"), second = try await reserve(store, "b")
        let broken = AsyncThrowingStream<[UInt8], Error> {
            $0.yield([UInt8](repeating: 1, count: 8))
            $0.finish(throwing: URLError(.networkConnectionLost))
        }

        let response = await CacheBlobUploadHandler(store: store).handle(
            method: "PUT", uploadID: first.uploadID, query: [URLQueryItem(name: "sig", value: first.signature)],
            headers: ["x-ms-blob-type": "BlockBlob"], body: broken)

        #expect(response.status == 400)
        #expect(!folder.files().contains { $0.hasPrefix("uploads/\(first.uploadID)/archive") })
        try await store.writePart(uploadID: second.uploadID, part: .whole, bytes: [UInt8](repeating: 2, count: 8))
    }

    @Test("concatenation stops at the size the block list projected")
    func concatenationLimit() async throws {
        defer { folder.cleanup() }
        let store = try makeStore(cap: 1000)
        let reservation = try await reserve(store, "k")
        try await store.writePart(uploadID: reservation.uploadID, part: block("a"), bytes: [1, 2, 3, 4])
        let blockFile = try #require(folder.files().first { $0.hasPrefix("uploads/\(reservation.uploadID)/block-") })
        let handle = try FileHandle(forWritingTo: folder.url.appendingPathComponent(blockFile))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 9, count: 100))
        try handle.close()

        await #expect(throws: CacheStoreError.self) {
            try await store.commitBlocks(uploadID: reservation.uploadID, order: [blockID("a")])
        }
        #expect(fileSizes().filter { $0.key.hasSuffix("/archive") }.values.allSatisfy { $0 <= 4 })
        #expect(await store.pendingUpload(reservation.uploadID)?.hasWhole != true)
    }

    @Test("blocks left out of the block list are dropped at commit")
    func unreferencedBlocks() async throws {
        defer { folder.cleanup() }
        let store = try makeStore(cap: 10)
        let first = try await reserve(store, "a"), second = try await reserve(store, "b")
        try await store.writePart(uploadID: first.uploadID, part: block("x"), bytes: [1, 1, 1, 1])
        try await store.writePart(uploadID: first.uploadID, part: block("y"), bytes: [2, 2, 2, 2])

        try await store.commitBlocks(uploadID: first.uploadID, order: [blockID("x")])

        #expect(folder.files().filter { $0.hasPrefix("uploads/\(first.uploadID)/block-") }.isEmpty)
        try await store.writePart(uploadID: second.uploadID, part: .whole, bytes: [UInt8](repeating: 3, count: 6))
    }
}
