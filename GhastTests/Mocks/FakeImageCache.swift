import Foundation
@testable import Ghast

/// An image cache held in memory, keyed by the path components joined with `/`. Records every read.
final class FakeImageCache: ImageCacheReading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var recorded: [[String]] = []

    init(_ files: [String: Data] = [:]) { self.files = files }

    var reads: [[String]] { lock.withLock { recorded } }

    func read(_ components: [String], maxBytes: Int) -> Data? {
        lock.withLock {
            recorded.append(components)
            guard let data = files[components.joined(separator: "/")], data.count <= maxBytes else { return nil }
            return data
        }
    }
}
