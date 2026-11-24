import Foundation
@testable import Ghast

/// Predictable IDs: `id-1`, `id-2`, … and `sig-1`, `sig-2`, …
final class SequentialCacheRandomness: CacheRandomness, @unchecked Sendable {
    private let lock = NSLock()
    private var ids = 0
    private var sigs = 0

    func id128() -> String { lock.withLock { ids += 1; return "id-\(ids)" } }
    func signature() -> String { lock.withLock { sigs += 1; return "sig-\(sigs)" } }
}

/// Writes through to disk until `failAfterBytes` would be exceeded, then throws `ENOSPC`.
final class FailingBlobWriter: CacheBlobWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0
    var failAfterBytes = Int.max

    func create(_ url: URL) throws -> any CacheFileSink {
        CheckedSink(real: try FileBlobWriter().create(url)) { [self] count in
            try lock.withLock {
                guard written + count <= failAfterBytes else { throw POSIXError(.ENOSPC) }
                written += count
            }
        }
    }
}

/// A real sink that asks `check` (which may throw or block) before each non-empty write.
final class CheckedSink: CacheFileSink, @unchecked Sendable {
    private let real: any CacheFileSink
    private let check: (Int) throws -> Void

    init(real: any CacheFileSink, check: @escaping (Int) throws -> Void) {
        self.real = real
        self.check = check
    }

    func write(_ bytes: some Collection<UInt8>) throws {
        if !bytes.isEmpty { try check(bytes.count) }
        try real.write(bytes)
    }

    func close() throws { try real.close() }
}

extension CacheStore {
    /// Writes one part in full: begin, write, finish.
    func writePart(uploadID: String, part: CacheUploadPart, bytes: [UInt8]) throws {
        let partWriter = try beginPart(uploadID: uploadID, part: part)
        try partWriter.write(bytes)
        try finishPart(partWriter)
    }
}

/// A temporary cache folder, removed by `cleanup()`.
struct CacheTestFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghast-cache-\(UUID().uuidString)")

    func cleanup() { try? FileManager.default.removeItem(at: url) }

    /// Every regular file under the folder, as paths relative to it, sorted.
    func files() -> [String] {
        let base = url.resolvingSymlinksInPath().pathComponents
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        let all = (enumerator?.allObjects as? [URL]) ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.resolvingSymlinksInPath().pathComponents.dropFirst(base.count).joined(separator: "/") }
            .sorted()
    }
}

/// Writes the index for real, except on the call numbers in `failingCalls` (1-based) or every
/// call while `failsAll` is set.
final class FailingIndexWriter: CacheIndexWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var failingCalls: Set<Int> = []
    var failsAll = false

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            calls += 1
            return failsAll || failingCalls.contains(calls)
        }
        if shouldFail { throw POSIXError(.EIO) }
        try AtomicIndexWriter().write(data, to: url)
    }

    var callCount: Int { lock.withLock { calls } }
}

/// Holds one write until the test opens it, so a test can act while a write is in progress.
/// The hold gives up after `limit` so a regression fails an expectation instead of hanging.
final class WriteGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasPassed = false
    private var gaveUp = false
    private let limit: DispatchTimeInterval

    init(limit: DispatchTimeInterval = .seconds(20)) { self.limit = limit }

    /// Called by the writer: the first caller blocks until `open()` (or the limit).
    func pass() {
        let isFirst = lock.withLock { () -> Bool in
            defer { hasPassed = true }
            return !hasPassed
        }
        guard isFirst else { return }
        entered.signal()
        if released.wait(timeout: .now() + limit) == .timedOut {
            lock.withLock { gaveUp = true }
        }
    }

    func open() { released.signal() }

    /// Whether the held write gave up waiting (the test didn't get to act during it).
    var didGiveUp: Bool { lock.withLock { gaveUp } }

    /// Waits, off the cooperative pool, until a write is being held.
    func waitUntilHolding() async {
        let entered = self.entered
        let limit = self.limit
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = entered.wait(timeout: .now() + limit)
                done.resume()
            }
        }
    }
}

/// A real writer whose first non-empty write to a file matching `holds` waits on `gate`.
final class GatedBlobWriter: CacheBlobWriting, @unchecked Sendable {
    let gate: WriteGate
    let holds: @Sendable (URL) -> Bool

    init(gate: WriteGate, holds: @escaping @Sendable (URL) -> Bool) {
        self.gate = gate
        self.holds = holds
    }

    func create(_ url: URL) throws -> any CacheFileSink {
        let real = try FileBlobWriter().create(url)
        guard holds(url) else { return real }
        return CheckedSink(real: real) { [gate] _ in gate.pass() }
    }
}
