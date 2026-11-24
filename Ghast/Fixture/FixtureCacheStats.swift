#if DEBUG
import Foundation

/// The design fixture's cache: canned usage, and changes that touch nothing on disk.
@MainActor
final class FixtureCacheStats: CacheStatsProviding {
    static let usage = CacheUsage(entryCount: 42, totalBytes: 18_400_000_000, pendingUploads: 0)

    func usage() async -> CacheUsage { Self.usage }
    func setCap(gigabytes: Int) async throws {}
    func clear() async throws {}
}
#endif
