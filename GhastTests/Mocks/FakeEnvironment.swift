import Foundation
@testable import Ghast

/// A clock that only moves when told to.
final class FakeClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

struct FakeHostInfo: HostInfo {
    var computerName = "Dionysus"
    var architecture = HostArchitecture.arm64
}

/// Records what it was asked to trash and removes nothing.
final class FakeFileTrasher: FileTrasher, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var failure: Error?

    var trashed: [URL] { lock.withLock { urls } }

    func trash(_ url: URL) async throws {
        if let failure { throw failure }
        lock.withLock { urls.append(url) }
    }
}
