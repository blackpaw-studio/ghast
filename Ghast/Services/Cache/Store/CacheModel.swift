import Foundation

/// A repository as the job token names it (`repository_id`, kept as the string GitHub sends).
struct CacheRepoID: Hashable, Codable, Sendable {
    let rawValue: String
}

/// What a token lets a job do with one cache scope (`ac` claim bits: read 1, write 2).
struct CachePermission: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int
    static let read = CachePermission(rawValue: 1)
    static let write = CachePermission(rawValue: 2)
}

/// One scope a token grants, such as `refs/heads/main`.
struct CacheScope: Hashable, Codable, Sendable {
    let name: String
    let permission: CachePermission
}

/// A finalized cache entry. `version` is an opaque string compared exactly.
struct CacheEntry: Equatable, Codable, Sendable {
    let id: String
    let repo: CacheRepoID
    let scope: String
    let key: String
    let version: String
    let sizeBytes: Int64
    let createdAt: Date
    var lastUsedAt: Date
    /// The random name of the archive file, also the download ID.
    let downloadID: String

    /// Whether this entry answers for `repo`, `scope`, `key` and `version` exactly.
    func isSlot(repo: CacheRepoID, scope: String, key: String, version: String) -> Bool {
        self.repo == repo && self.scope == scope && self.key == key && self.version == version
    }
}

/// The set of finalized entries, as a value.
struct CacheIndex: Equatable, Codable, Sendable {
    var entries: [CacheEntry] = []

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeBytes } }

    /// The entry a restore gets: for each read scope in order, the primary key and then each
    /// restore key, an exact key before a prefix match, the newest prefix match first. Only
    /// `repo`'s entries with exactly `version` are candidates. Empty keys are ignored, so an
    /// empty restore key never matches everything.
    func match(repo: CacheRepoID, readScopes: [String], key: String, restoreKeys: [String], version: String) -> CacheEntry? {
        let candidates = entries.filter { $0.repo == repo && $0.version == version }
        let wanted = ([key] + restoreKeys).filter { !$0.isEmpty }
        for scope in readScopes {
            let inScope = candidates.filter { $0.scope == scope }
            for prefix in wanted {
                if let exact = Self.newest(inScope.filter { $0.key == prefix }) { return exact }
                if let partial = Self.newest(inScope.filter { $0.key.hasPrefix(prefix) }) { return partial }
            }
        }
        return nil
    }

    private static func newest(_ entries: [CacheEntry]) -> CacheEntry? {
        entries.max { $0.createdAt < $1.createdAt }
    }
}
