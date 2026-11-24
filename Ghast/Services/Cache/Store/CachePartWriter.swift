import Foundation

/// Writes one upload part straight to its own file, off the store's actor, so uploads from
/// different VMs don't wait for each other. Made by `CacheStore.beginPart`; the caller writes
/// the body with `write` and then always calls `CacheStore.finishPart` (or `abandonPart` when
/// the request ends early). A newer writer for the same part closes this one at once.
final class CachePartWriter: @unchecked Sendable {
    let uploadID: String
    let part: CacheUploadPart
    let file: CacheUploadFile
    private let clock: any AppClock
    private let budget: CacheByteBudget
    private let lock = NSLock()
    private var lastWriteAt: Date
    private var failure: String?

    init(uploadID: String, part: CacheUploadPart, file: CacheUploadFile, clock: any AppClock, budget: CacheByteBudget) {
        self.uploadID = uploadID
        self.part = part
        self.file = file
        self.clock = clock
        self.budget = budget
        lastWriteAt = clock.now()
    }

    /// Appends bytes. Throws `unknownUpload` once the store closed this writer (superseded or
    /// the upload dropped), `tooLarge` when pending uploads would pass the cache cap (the
    /// caller then abandons the part), and `writeFailed` after a write error (the store then
    /// drops the upload in `finishPart`).
    func write(_ bytes: some Collection<UInt8>) throws {
        if let failure = lock.withLock({ failure }) { throw CacheStoreError.writeFailed(failure) }
        do {
            try file.append(bytes)
        } catch .closed {
            throw CacheStoreError.unknownUpload
        } catch .overBudget(let charged) {
            throw CacheStoreError.tooLarge(sizeBytes: charged + Int64(bytes.count), capBytes: budget.limit)
        } catch .write(let error) {
            let reason = String(describing: error)
            lock.withLock { failure = reason }
            throw CacheStoreError.writeFailed(reason)
        }
        let now = clock.now()
        lock.withLock { lastWriteAt = now }
    }

    var lastActivity: Date { lock.withLock { lastWriteAt } }
    var writeFailure: String? { lock.withLock { failure } }
}
