import Foundation

/// One file of a pending upload (a part being written, a finished part, or an archive being
/// built) and its share of the byte budget. Bytes are charged as they are written. The charge
/// is released exactly once, only when the file is closed and removed (`discard`) or has
/// become an entry's archive (`adopt`), so the budget never forgets a file that is still open
/// or still on disk. A discard while a write or a read is in flight closes the file to new
/// work at once and finishes when that write or read ends.
final class CacheUploadFile: @unchecked Sendable {
    enum AppendError: Error {
        case closed
        case overBudget(charged: Int64)
        case write(Error)
    }

    let url: URL
    private let budget: CacheByteBudget
    private let lock = NSLock()
    private var sink: (any CacheFileSink)?
    private var isWriting = false
    private var readers = 0
    private var isClosedToWrites = false
    private var isDiscardRequested = false
    private var isDone = false
    private var isReleased = false

    init(url: URL, sink: any CacheFileSink, budget: CacheByteBudget) {
        self.url = url
        self.sink = sink
        self.budget = budget
    }

    private var owner: CacheByteBudget.Owner { ObjectIdentifier(self) }

    /// Bytes this file holds against the budget.
    var charged: Int64 { budget.charge(of: owner) }

    /// Closed to writes: superseded, discarded or finished.
    var isClosed: Bool { lock.withLock { isClosedToWrites } }

    /// Appends `bytes`, charging them first. One write at a time per file.
    func append(_ bytes: some Collection<UInt8>) throws(AppendError) {
        let count = Int64(bytes.count)
        let open = try startWrite(count).get()
        var failure: Error?
        do { try open.write(bytes) } catch { failure = error }
        let finish = lock.withLock { () -> Bool in
            isWriting = false
            return isDiscardRequested && readers == 0
        }
        if finish { finishDiscard() }
        if let failure { throw .write(failure) }
    }

    private func startWrite(_ count: Int64) -> Result<any CacheFileSink, AppendError> {
        lock.withLock {
            guard !isClosedToWrites, !isWriting, let sink else { return .failure(.closed) }
            guard budget.charge(owner, count) else { return .failure(.overBudget(charged: budget.charge(of: owner))) }
            isWriting = true
            return .success(sink)
        }
    }

    /// Closes the file to writes now. The file stays (and stays charged) until `discard` or
    /// `adopt`. A write in flight completes and is the last.
    func close() throws {
        let open = lock.withLock { () -> (any CacheFileSink)? in
            isClosedToWrites = true
            guard !isWriting else { return nil }
            defer { sink = nil }
            return sink
        }
        try open?.close()
    }

    /// Opens the file for a reader; false once a discard was asked for.
    func beginReading() -> Bool {
        lock.withLock {
            guard !isDiscardRequested else { return false }
            readers += 1
            return true
        }
    }

    func endReading() {
        let finish = lock.withLock { () -> Bool in
            readers -= 1
            return isDiscardRequested && readers == 0 && !isWriting
        }
        if finish { finishDiscard() }
    }

    /// Closes and removes the file and then releases its charge; when a write or read is in
    /// flight, that happens as soon as it ends. Discarding twice is harmless.
    func discard() {
        let now = lock.withLock { () -> Bool in
            isClosedToWrites = true
            isDiscardRequested = true
            return !isWriting && readers == 0
        }
        if now { finishDiscard() }
    }

    /// Whether the file is gone and its charge released (discarded, or adopted by an entry).
    /// A file that couldn't be removed stays unfinished, and charged, until a later `discard`
    /// removes it.
    var isFinished: Bool { lock.withLock { isReleased } }

    /// Moves the closed file to `destination` (an entry's archive), then releases its charge:
    /// the bytes now belong to the entry.
    func adopt(movingTo destination: URL) throws {
        try lock.withLock {
            guard !isDone, !isWriting, readers == 0, !isDiscardRequested else { throw CacheStoreError.unknownUpload }
            try? sink?.close()
            sink = nil
            isClosedToWrites = true
            try FileManager.default.moveItem(at: url, to: destination)
            isDone = true
            isReleased = true
        }
        budget.release(owner)
    }

    /// Closes the sink once, then removes the file; a removal that fails is retried by the next
    /// `discard`. The charge is released only once the file is gone.
    private func finishDiscard() {
        let open = lock.withLock { () -> (any CacheFileSink)?? in
            guard !isReleased else { return .none }
            isDone = true
            defer { sink = nil }
            return .some(sink)
        }
        guard case let .some(sink) = open else { return }
        try? sink?.close()
        let manager = FileManager.default
        // A file that can't be removed keeps its charge: the budget never forgets bytes on disk.
        guard (try? manager.removeItem(at: url)) != nil || !manager.fileExists(atPath: url.path) else { return }
        let isFirstRelease = lock.withLock { () -> Bool in
            defer { isReleased = true }
            return !isReleased
        }
        if isFirstRelease { budget.release(owner) }
    }
}
