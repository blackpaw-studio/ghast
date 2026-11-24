import Foundation
import Synchronization

/// Bytes on disk held by pending uploads, capped at the cache size, so no upload (or several
/// together) can write more than the cap. Part writers grow their own share as they write,
/// off the store's actor; the store moves a finished writer's bytes to its part, and drops an
/// upload's bytes when the upload is finalized or dropped.
final class CacheByteBudget: Sendable {
    enum Holder: Hashable, Sendable {
        case writer(ObjectIdentifier)
        case part(CacheUploadPart)
    }

    struct Key: Hashable, Sendable {
        let uploadID: String
        let holder: Holder
    }

    private struct State {
        var limit: Int64
        var bytes: [Key: Int64] = [:]
        var total: Int64 = 0
    }

    private let state: Mutex<State>

    init(limit: Int64) { state = Mutex(State(limit: limit)) }

    var limit: Int64 { state.withLock { $0.limit } }
    var total: Int64 { state.withLock { $0.total } }

    func setLimit(_ limit: Int64) { state.withLock { $0.limit = limit } }

    func bytes(_ key: Key) -> Int64 { state.withLock { $0.bytes[key] ?? 0 } }

    /// Adds `count` bytes to `key` if the total stays within the limit.
    func grow(_ key: Key, by count: Int64) -> Bool {
        state.withLock { state in
            guard count >= 0, state.total + count <= state.limit else { return false }
            state.bytes[key, default: 0] += count
            state.total += count
            return true
        }
    }

    /// Removes `key` and returns its bytes.
    @discardableResult
    func take(_ key: Key) -> Int64 {
        state.withLock { state in
            let bytes = state.bytes.removeValue(forKey: key) ?? 0
            state.total -= bytes
            return bytes
        }
    }

    /// Records bytes already on disk (moved from another key), whatever the limit.
    func add(_ key: Key, _ count: Int64) {
        guard count > 0 else { return }
        state.withLock { state in
            state.bytes[key, default: 0] += count
            state.total += count
        }
    }

    func releaseUpload(_ uploadID: String) {
        state.withLock { state in
            for key in state.bytes.keys where key.uploadID == uploadID {
                state.total -= state.bytes.removeValue(forKey: key) ?? 0
            }
        }
    }

    func releaseAll() {
        state.withLock { state in
            state.bytes = [:]
            state.total = 0
        }
    }
}
