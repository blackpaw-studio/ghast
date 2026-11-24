import Foundation

/// Writes one upload part straight to its file, off the store's actor, so uploads from
/// different VMs don't wait for each other. Made by `CacheStore.beginPart`; the caller writes
/// the body with `write` and then always calls `CacheStore.finishPart` (or `abandonPart` when
/// the request ends early).
final class CachePartWriter: @unchecked Sendable {
    let uploadID: String
    let part: CacheUploadPart
    private let sink: any CacheFileSink
    private let clock: any AppClock
    private let budget: CacheByteBudget
    private let lock = NSLock()
    private var lastWriteAt: Date
    private var failure: String?
    private var isCancelled = false

    init(uploadID: String, part: CacheUploadPart, sink: any CacheFileSink, clock: any AppClock, budget: CacheByteBudget) {
        self.uploadID = uploadID
        self.part = part
        self.sink = sink
        self.clock = clock
        self.budget = budget
        lastWriteAt = clock.now()
    }

    /// This writer's share of the upload byte budget.
    var budgetKey: CacheByteBudget.Key { .init(uploadID: uploadID, holder: .writer(ObjectIdentifier(self))) }

    /// Appends bytes. Throws `unknownUpload` once the store dropped the upload, `tooLarge`
    /// when pending uploads would pass the cache cap (the caller then abandons the part), and
    /// `writeFailed` after a write error (the store then drops the upload in `finishPart`).
    func write(_ bytes: some Collection<UInt8>) throws {
        try lock.withLock {
            if isCancelled { throw CacheStoreError.unknownUpload }
            if let failure { throw CacheStoreError.writeFailed(failure) }
        }
        let count = Int64(bytes.count)
        guard budget.grow(budgetKey, by: count) else {
            throw CacheStoreError.tooLarge(sizeBytes: budget.bytes(budgetKey) + count, capBytes: budget.limit)
        }
        do {
            try sink.write(bytes)
        } catch {
            let reason = String(describing: error)
            lock.withLock { failure = reason }
            throw CacheStoreError.writeFailed(reason)
        }
        let now = clock.now()
        lock.withLock { lastWriteAt = now }
    }

    var lastActivity: Date { lock.withLock { lastWriteAt } }
    var writeFailure: String? { lock.withLock { failure } }
    var wasCancelled: Bool { lock.withLock { isCancelled } }

    /// Called by the store when it drops the upload; later writes throw `unknownUpload`.
    func cancel() { lock.withLock { isCancelled = true } }

    func close() throws { try sink.close() }
}
