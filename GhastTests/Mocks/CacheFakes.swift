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
    private let real = FileBlobWriter()
    private var written = 0
    var failAfterBytes = Int.max

    func append(_ bytes: some Collection<UInt8>, to url: URL) throws {
        try lock.withLock {
            guard written + bytes.count <= failAfterBytes else { throw POSIXError(.ENOSPC) }
            written += bytes.count
        }
        try real.append(bytes, to: url)
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
