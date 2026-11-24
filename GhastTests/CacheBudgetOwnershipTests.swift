import Foundation
import Testing
@testable import Ghast

/// Every upload file owns its share of the byte budget: charged as written, released once,
/// only when the file is closed and gone (or became an entry's archive).
@Suite("Cache upload budget ownership")
struct CacheBudgetOwnershipTests {
    private let folder = CacheTestFolder()
    private let clock = FakeClock()
    private let repo = CacheRepoID(rawValue: "1")

    private func makeStore(cap: Int64, writer: AccountingBlobWriter) throws -> CacheStore {
        try CacheStore(root: folder.url, clock: clock, randomness: SequentialCacheRandomness(), writer: writer, capBytes: cap)
    }

    @Test("a writer that fills the cap and stays open, superseded by an empty upload that finalizes, can't pile up past the cap")
    func supersededWriterAttack() async throws {
        defer { folder.cleanup() }
        let writer = AccountingBlobWriter()
        let store = try makeStore(cap: 10, writer: writer)

        for round in 0 ..< 4 {
            let reservation = try #require(try await store.reserve(repo: repo, scope: "s", key: "k\(round)", version: "v"))
            let attacker = try await store.beginPart(uploadID: reservation.uploadID, part: .whole)
            try attacker.write([UInt8](repeating: 1, count: 10))  // never finished: the body just stalls
            let empty = try await store.beginPart(uploadID: reservation.uploadID, part: .whole)
            try await store.finishPart(empty)
            _ = try await store.finalize(repo: repo, scope: "s", key: "k\(round)", version: "v", sizeBytes: 0)

            #expect(throws: CacheStoreError.unknownUpload) { try attacker.write([1]) }
            #expect(await store.uploadBytesCharged() <= 10)
            #expect(writer.uploadDiskBytes(root: folder.url) <= 10, "round \(round)")
        }
    }

    /// Replays random sequences of what clients and housekeeping do, checking after every step
    /// that the budget holds exactly the bytes upload files hold on disk.
    @Test("random begin, write, supersede, abandon, finish, commit, finalize, clear and sweep keep the budget equal to the bytes on disk",
          arguments: 1 ... 6 as ClosedRange<UInt64>)
    func randomSequences(seed: UInt64) async throws {
        defer { folder.cleanup() }
        let writer = AccountingBlobWriter()
        let store = try makeStore(cap: 16, writer: writer)
        var random = SplitMix(seed: seed)
        var uploads: [(id: String, key: String)] = []
        var writers: [CachePartWriter] = []
        var keys = 0
        let parts: [CacheUploadPart] = [.whole, .block(id: "YQ=="), .block(id: "Yg=="), .block(id: "Yw==")]

        for step in 0 ..< 300 {
            let action = random.int(100)
            switch action {
            case ..<10:
                keys += 1
                if let reservation = try await store.reserve(repo: repo, scope: "s", key: "k\(keys)", version: "v") {
                    uploads.append((reservation.uploadID, "k\(keys)"))
                }
            case ..<30 where !uploads.isEmpty:
                let upload = uploads[random.int(uploads.count)]
                if let started = try? await store.beginPart(uploadID: upload.id, part: parts[random.int(parts.count)]) {
                    writers.append(started)
                }
            case ..<55 where !writers.isEmpty:
                let index = random.int(writers.count)
                do {
                    try writers[index].write([UInt8](repeating: UInt8(step % 251), count: 1 + random.int(4)))
                } catch CacheStoreError.tooLarge {
                    await store.abandonPart(writers.remove(at: index))
                } catch {
                    try? await store.finishPart(writers.remove(at: index))
                }
            case ..<67 where !writers.isEmpty:
                try? await store.finishPart(writers.remove(at: random.int(writers.count)))
            case ..<74 where !writers.isEmpty:
                await store.abandonPart(writers.remove(at: random.int(writers.count)))
            case ..<82 where !uploads.isEmpty:
                let upload = uploads[random.int(uploads.count)]
                let order = ["YQ==", "Yg==", "Yw=="].filter { _ in random.int(2) == 0 }
                try? await store.commitBlocks(uploadID: upload.id, order: order)
            case ..<90 where !uploads.isEmpty:
                let upload = uploads.remove(at: random.int(uploads.count))
                _ = try? await store.finalize(repo: repo, scope: "s", key: upload.key, version: "v", sizeBytes: Int64(random.int(12)))
            case ..<93:
                try await store.clear()
                uploads = []
            case ..<96:
                clock.advance(by: 11 * 60)
                try await store.sweep()
            default:
                try await store.setCapBytes(Int64(8 + random.int(16)))
            }

            let charged = await store.uploadBytesCharged()
            let onDisk = writer.uploadDiskBytes(root: folder.url)
            #expect(charged == onDisk, "seed \(seed), step \(step), action \(action)")
            if charged != onDisk { return }
        }
    }
}

/// A small deterministic generator, so a failing seed replays exactly.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
}
