import Foundation
import Testing
@testable import Ghast

@Suite("Cache eviction and expiry")
struct CacheEvictionTests {
    private let folder = CacheTestFolder()
    private let clock = FakeClock()
    private let repo = CacheRepoID(rawValue: "42")
    private let main = "refs/heads/main"
    private static let day: TimeInterval = 24 * 60 * 60

    private func makeStore(capBytes: Int64 = .max) throws -> CacheStore {
        try CacheStore(root: folder.url, clock: clock, randomness: SequentialCacheRandomness(), writer: FileBlobWriter(),
                       capBytes: capBytes)
    }

    @discardableResult
    private func save(_ store: CacheStore, key: String, size: Int = 5) async throws -> CacheEntry {
        let bytes = [UInt8](repeating: 7, count: size)
        let id = try #require(try await store.reserve(repo: repo, scope: main, key: key, version: "v1")).uploadID
        try await store.beginPart(uploadID: id, part: .whole)
        try await store.appendPart(uploadID: id, part: .whole, bytes: bytes)
        return try await store.finalize(repo: repo, scope: main, key: key, version: "v1", sizeBytes: Int64(size))
    }

    private func has(_ store: CacheStore, _ key: String) async -> Bool {
        await store.lookup(repo: repo, readScopes: [main], key: key, restoreKeys: [], version: "v1")?.key == key
    }

    private func blobFiles() -> [String] { folder.files().filter { $0.hasPrefix("blobs/") } }

    @Test("eviction removes the least recently used entry, not the oldest created")
    func lruByLastUse() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        try await save(store, key: "a")
        clock.advance(by: 10)
        try await save(store, key: "b")
        clock.advance(by: 10)
        #expect(await has(store, "a"))

        try await store.evict(capBytes: 5)

        #expect(await store.usage().entryCount == 1)
        #expect(await has(store, "a"))
        #expect(blobFiles().count == 1)
    }

    @Test("the size cap holds after each finalize, keeping the newest entries")
    func capAfterFinalize() async throws {
        defer { folder.cleanup() }
        let store = try makeStore(capBytes: 10)
        for key in ["a", "b", "c"] {
            try await save(store, key: key)
            clock.advance(by: 1)
        }
        #expect(await store.usage().totalBytes == 10)
        #expect(await has(store, "c"))
        #expect(await has(store, "b"))
        #expect(!(await has(store, "a")))
        #expect(blobFiles().count == 2)
    }

    @Test("an entry unused for exactly 7 days is kept; one unused for longer is removed")
    func expiryBoundary() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        try await save(store, key: "a")

        clock.advance(by: 7 * Self.day)
        try await store.sweep()
        #expect(await store.usage().entryCount == 1)

        clock.advance(by: 1)
        try await store.sweep()
        #expect(await store.usage().entryCount == 0)
        #expect(blobFiles().isEmpty)
    }

    @Test("an upload idle for more than 10 minutes is dropped with its files")
    func idleUpload() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let id = try #require(try await store.reserve(repo: repo, scope: main, key: "a", version: "v1")).uploadID
        try await store.beginPart(uploadID: id, part: .whole)

        clock.advance(by: 10 * 60)
        try await store.sweep()
        #expect(await store.usage().pendingUploads == 1)

        clock.advance(by: 1)
        try await store.sweep()
        #expect(await store.usage().pendingUploads == 0)
        #expect(folder.files().allSatisfy { !$0.hasPrefix("uploads/") })
        await #expect(throws: CacheStoreError.unknownUpload) {
            try await store.appendPart(uploadID: id, part: .whole, bytes: [1])
        }
    }

    @Test("the sweep removes files no entry or upload names (left by a crash)")
    func orphans() async throws {
        defer { folder.cleanup() }
        let store = try makeStore()
        let kept = try await save(store, key: "a")
        let stray = folder.url.appendingPathComponent("blobs/stray")
        let strayUpload = folder.url.appendingPathComponent("uploads/old/archive")
        try FileManager.default.createDirectory(at: strayUpload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: stray)
        try Data([1]).write(to: strayUpload)

        try await store.sweep()

        #expect(blobFiles() == ["blobs/\(kept.downloadID)"])
        #expect(folder.files().allSatisfy { !$0.hasPrefix("uploads/") })
    }

    @Test("the sweeper sweeps once per tick and stops when cancelled")
    @MainActor
    func sweeperTicks() async throws {
        let sleeper = ManualSleeper()
        let count = SweepCounter()
        let sweeper = CacheSweeper(sleeper: sleeper.sleeper, interval: .seconds(3600)) { await count.increment() }
        let task = Task { await sweeper.run() }

        await waitUntil { sleeper.requested.count == 1 }
        #expect(sleeper.requested == [.seconds(3600)])
        sleeper.wakeAll()
        await waitUntil { sleeper.requested.count == 2 }
        #expect(await count.value == 1)

        task.cancel()
        sleeper.wakeAll()
        await task.value
        #expect(await count.value == 1)
    }

    /// Yields until `condition` holds, giving up after a bounded number of turns so a bug fails
    /// the next expectation instead of hanging the suite.
    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
    }
}

private actor SweepCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
