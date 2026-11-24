import Foundation
@testable import Ghast

/// A cache store that records the housekeeping calls made on it.
actor FakeCacheMaintainer: CacheMaintaining {
    private(set) var calls: [String] = []
    var currentUsage = CacheUsage(entryCount: 0, totalBytes: 0, pendingUploads: 0)

    func usage() -> CacheUsage { currentUsage }
    func setCapBytes(_ bytes: Int64) { calls.append("setCap \(bytes)") }
    func sweep() { calls.append("sweep") }
    func clear() { calls.append("clear") }
    func flush() { calls.append("flush") }
}
