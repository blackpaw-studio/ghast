import Foundation
import Testing
@testable import Ghast

@Suite("Cache store persistence and uploads")
struct CacheStoreTests {
    private let folder = CacheTestFolder()
    private let clock = FakeClock()
    private let writer = FailingBlobWriter()
    private let repo = CacheRepoID(rawValue: "42")
    private let main = "refs/heads/main"

    private func makeStore() throws -> CacheStore {
        try CacheStore(root: folder.url, clock: clock, randomness: SequentialCacheRandomness(), writer: writer)
    }

    /// Reserves, uploads `bytes` in one part and finalizes; returns the entry.
    @discardableResult
    private func save(_ store: CacheStore, key: String, bytes: [UInt8] = Array("hello".utf8)) async throws -> CacheEntry {
        let reservation = try #require(try await store.reserve(repo: repo, scope: main, key: key, version: "v1"))
        try await store.beginPart(uploadID: reservation.uploadID, part: .whole)
        try await store.appendPart(uploadID: reservation.uploadID, part: .whole, bytes: bytes)
        return try await store.finalize(repo: repo, scope: main, key: key, version: "v1", sizeBytes: Int64(bytes.count))
    }

    private func lookup(_ store: CacheStore, _ key: String) async -> CacheEntry? {
        await store.lookup(repo: repo, readScopes: [main], key: key, restoreKeys: [], version: "v1")
    }

    @Test("an entry is invisible until finalize, then restores its bytes")
    func invisibleBeforeFinalize() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let reservation = try #require(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1"))
        try await store.beginPart(uploadID: reservation.uploadID, part: .whole)
        try await store.appendPart(uploadID: reservation.uploadID, part: .whole, bytes: Array("abc".utf8))
        #expect(await lookup(store, "deps") == nil)

        _ = try await store.finalize(repo: repo, scope: main, key: "deps", version: "v1", sizeBytes: 3)

        let entry = try #require(await lookup(store, "deps"))
        let blob = try #require(await store.blobURL(downloadID: entry.downloadID))
        #expect(try Data(contentsOf: blob) == Data("abc".utf8))
    }

    @Test("a second reserve for the same slot is refused, while uploading and after finalize")
    func duplicateReserve() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let first = try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1")
        #expect(first != nil)
        #expect(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1") == nil)
        #expect(try await store.reserve(repo: repo, scope: "refs/heads/other", key: "deps", version: "v1") != nil)

        try await store.beginPart(uploadID: try #require(first).uploadID, part: .whole)
        _ = try await store.finalize(repo: repo, scope: main, key: "deps", version: "v1", sizeBytes: 0)
        #expect(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1") == nil)
    }

    @Test("finalize with the wrong size is rejected and nothing becomes visible")
    func wrongSize() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let reservation = try #require(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1"))
        try await store.beginPart(uploadID: reservation.uploadID, part: .whole)
        try await store.appendPart(uploadID: reservation.uploadID, part: .whole, bytes: Array("abc".utf8))

        await #expect(throws: CacheStoreError.sizeMismatch(expected: 4, actual: 3)) {
            try await store.finalize(repo: repo, scope: main, key: "deps", version: "v1", sizeBytes: 4)
        }
        #expect(await lookup(store, "deps") == nil)
        #expect(folder.files().allSatisfy { !$0.hasPrefix("uploads/") })
    }

    @Test("blocks commit in list order, not arrival order")
    func blockOrder() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let id = try #require(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1")).uploadID
        for (block, text) in [("Yg==", "second"), ("YQ==", "first-")] {
            try await store.beginPart(uploadID: id, part: .block(id: block))
            try await store.appendPart(uploadID: id, part: .block(id: block), bytes: Array(text.utf8))
        }
        try await store.commitBlocks(uploadID: id, order: ["YQ==", "Yg=="])
        let entry = try await store.finalize(repo: repo, scope: main, key: "deps", version: "v1", sizeBytes: 12)

        let blob = try #require(await store.blobURL(downloadID: entry.downloadID))
        #expect(try String(contentsOf: blob, encoding: .utf8) == "first-second")
    }

    @Test("a block list naming a block that was never uploaded fails")
    func missingBlock() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let id = try #require(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1")).uploadID
        try await store.beginPart(uploadID: id, part: .block(id: "YQ=="))
        await #expect(throws: CacheStoreError.missingBlock(id: "Yg==")) {
            try await store.commitBlocks(uploadID: id, order: ["YQ==", "Yg=="])
        }
    }

    @Test("entries and their recency survive reopening the store")
    func reload() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        try await save(store, key: "deps")
        clock.advance(by: 60)
        let used = try #require(await lookup(store, "deps"))
        try await store.flush()

        let reopened = try makeStore()
        let entry = try #require(await lookup(reopened, "deps"))
        #expect(entry.downloadID == used.downloadID)
        #expect(entry.createdAt < used.lastUsedAt)
        #expect(await reopened.usage() == CacheUsage(entryCount: 1, totalBytes: 5, pendingUploads: 0))
    }

    @Test("a disk-full write aborts that upload, leaves no partial files and reports the error")
    func diskFull() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        writer.failAfterBytes = 4
        let id = try #require(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1")).uploadID
        try await store.beginPart(uploadID: id, part: .whole)

        await #expect {
            try await store.appendPart(uploadID: id, part: .whole, bytes: Array("too long".utf8))
        } throws: { error in
            guard case CacheStoreError.writeFailed = error else { return false }
            return true
        }
        #expect(folder.files().filter { !$0.hasSuffix(CacheStore.indexFileName) }.isEmpty)
        await #expect(throws: CacheStoreError.unknownUpload) {
            try await store.appendPart(uploadID: id, part: .whole, bytes: Array("x".utf8))
        }
        #expect(try await store.reserve(repo: repo, scope: main, key: "deps", version: "v1") != nil)
    }

    @Test("clear drops entries and an upload in progress, whose next write fails cleanly")
    func clearDropsUpload() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        try await save(store, key: "old")
        let id = try #require(try await store.reserve(repo: repo, scope: main, key: "new", version: "v1")).uploadID
        try await store.beginPart(uploadID: id, part: .whole)

        try await store.clear()

        await #expect(throws: CacheStoreError.unknownUpload) {
            try await store.appendPart(uploadID: id, part: .whole, bytes: Array("x".utf8))
        }
        #expect(await lookup(store, "old") == nil)
        #expect(await store.usage() == CacheUsage(entryCount: 0, totalBytes: 0, pendingUploads: 0))
        #expect(folder.files().filter { !$0.hasSuffix(CacheStore.indexFileName) }.isEmpty)
    }
}
