import Foundation
@testable import Ghast

/// Settings' view of the cache, recording each change; `failure` makes the next change throw.
@MainActor
final class FakeCacheStats: CacheStatsProviding {
    struct Failure: LocalizedError { var errorDescription: String? { "the disk is full" } }

    var currentUsage = CacheUsage(entryCount: 0, totalBytes: 0, pendingUploads: 0)
    var failure: Failure?
    private(set) var calls: [String] = []

    func usage() async -> CacheUsage { currentUsage }

    func setCap(gigabytes: Int) async throws {
        calls.append("setCap \(gigabytes)")
        if let failure { throw failure }
    }

    func clear() async throws {
        calls.append("clear")
        if let failure { throw failure }
        currentUsage = CacheUsage(entryCount: 0, totalBytes: 0, pendingUploads: 0)
    }
}
