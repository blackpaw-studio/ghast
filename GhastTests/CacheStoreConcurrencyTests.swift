import Foundation
import Testing
@testable import Ghast

@Suite("Cache store I/O off the actor")
struct CacheStoreConcurrencyTests {
    private let folder = CacheTestFolder()
    private let clock = FakeClock()
    private let repo = CacheRepoID(rawValue: "42")
    private let main = "refs/heads/main"

    private func makeStore(writer: any CacheBlobWriting = FileBlobWriter()) throws -> CacheStore {
        try CacheStore(root: folder.url, clock: clock, randomness: SequentialCacheRandomness(), writer: writer)
    }

    private func uploadFiles() -> [String] { folder.files().filter { $0.hasPrefix("uploads/") } }

    /// Reserves `key` and uploads two blocks out of order ("Yg==" then "YQ==").
    private func uploadBlocks(_ store: CacheStore, key: String) async throws -> String {
        let id = try #require(try await store.reserve(repo: repo, scope: main, key: key, version: "v1")).uploadID
        for (block, text) in [("Yg==", "second"), ("YQ==", "first-")] {
            try await store.writePart(uploadID: id, part: .block(id: block), bytes: Array(text.utf8))
        }
        return id
    }

    @Test("another upload finishes while one upload's write is in progress")
    func uploadsDoNotSerialize() async throws {
        defer { folder.cleanup() }
        let gate = WriteGate()
        let store = try makeStore(writer: GatedBlobWriter(gate: gate) { $0.path.contains("/id-1/") })
        let slow = try #require(try await store.reserve(repo: repo, scope: main, key: "slow", version: "v1")).uploadID
        let slowWriter = try await store.beginPart(uploadID: slow, part: .whole)
        let slowWrite = Task.detached { try slowWriter.write([1]) }
        await gate.waitUntilHolding()

        let fast = try #require(try await store.reserve(repo: repo, scope: main, key: "fast", version: "v1")).uploadID
        try await store.writePart(uploadID: fast, part: .whole, bytes: [2])
        _ = try await store.finalize(repo: repo, scope: main, key: "fast", version: "v1", sizeBytes: 1)

        #expect(!gate.didGiveUp)
        gate.open()
        try await slowWrite.value
        try await store.finishPart(slowWriter)
    }

    @Test("a block commit that clear drops midway leaves nothing behind")
    func clearDuringCommit() async throws {
        defer { folder.cleanup() }
        let gate = WriteGate()
        let store = try makeStore(writer: GatedBlobWriter(gate: gate) { $0.lastPathComponent.hasPrefix("archive") })
        let id = try await uploadBlocks(store, key: "deps")
        let commit = Task { try await store.commitBlocks(uploadID: id, order: ["YQ==", "Yg=="]) }
        await gate.waitUntilHolding()

        try await store.clear()
        gate.open()

        #expect(!gate.didGiveUp)
        await #expect(throws: CacheStoreError.unknownUpload) { try await commit.value }
        #expect(uploadFiles().isEmpty)
    }

    @Test("block files are deleted once the archive is built, and kept for a retry until then")
    func blockFilesAfterCommit() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let id = try await uploadBlocks(store, key: "deps")

        await #expect(throws: CacheStoreError.missingBlock(id: "Yw==")) {
            try await store.commitBlocks(uploadID: id, order: ["YQ==", "Yg==", "Yw=="])
        }
        try await store.commitBlocks(uploadID: id, order: ["YQ==", "Yg=="])

        #expect(uploadFiles().count == 1)
        #expect(uploadFiles().allSatisfy { $0.hasPrefix("uploads/\(id)/archive") })
        let entry = try await store.finalize(repo: repo, scope: main, key: "deps", version: "v1", sizeBytes: 12)
        let blob = try #require(await store.blobURL(downloadID: entry.downloadID))
        #expect(try String(contentsOf: blob, encoding: .utf8) == "first-second")
    }
}
