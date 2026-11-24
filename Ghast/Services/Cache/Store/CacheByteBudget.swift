import Foundation
import Synchronization

/// Bytes on disk held by pending uploads, capped at the cache size, so no upload (or several
/// together) can write more than the cap. Each upload file (`CacheUploadFile`) owns one
/// charge: it grows as the file is written and is released once, when the file is gone.
final class CacheByteBudget: Sendable {
    typealias Owner = ObjectIdentifier

    private struct State {
        var limit: Int64
        var charges: [Owner: Int64] = [:]
        var total: Int64 = 0
    }

    private let state: Mutex<State>

    init(limit: Int64) { state = Mutex(State(limit: limit)) }

    var limit: Int64 { state.withLock { $0.limit } }
    var total: Int64 { state.withLock { $0.total } }

    func setLimit(_ limit: Int64) { state.withLock { $0.limit = limit } }

    func charge(of owner: Owner) -> Int64 { state.withLock { $0.charges[owner] ?? 0 } }

    /// Adds `count` bytes to `owner`'s charge if the total stays within the limit.
    func charge(_ owner: Owner, _ count: Int64) -> Bool {
        state.withLock { state in
            guard count >= 0, state.total + count <= state.limit else { return false }
            state.charges[owner, default: 0] += count
            state.total += count
            return true
        }
    }

    /// Drops `owner`'s charge. Releasing twice is harmless.
    func release(_ owner: Owner) {
        state.withLock { state in
            state.total -= state.charges.removeValue(forKey: owner) ?? 0
        }
    }

    /// Whether every charge belongs to one of `owners` (none leaked to a file nobody tracks).
    func isHeld(only owners: Set<Owner>) -> Bool {
        state.withLock { state in state.charges.keys.allSatisfy(owners.contains) }
    }
}
