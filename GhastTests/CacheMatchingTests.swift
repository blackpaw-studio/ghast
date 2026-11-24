import Foundation
import Testing
@testable import Ghast

@Suite("Cache key matching")
struct CacheMatchingTests {
    private let repoA = CacheRepoID(rawValue: "1")
    private let repoB = CacheRepoID(rawValue: "2")
    private let main = "refs/heads/main"
    private let feature = "refs/heads/feature"

    private func entry(_ key: String, repo: CacheRepoID? = nil, scope: String? = nil, version: String = "v1", age: TimeInterval = 0) -> CacheEntry {
        let created = Date(timeIntervalSince1970: 1_000_000 - age)
        return CacheEntry(id: "\(key)-\(age)", repo: repo ?? repoA, scope: scope ?? main, key: key, version: version,
                          sizeBytes: 1, createdAt: created, lastUsedAt: created, downloadID: "d-\(key)-\(age)")
    }

    private func match(_ entries: [CacheEntry], key: String, restoreKeys: [String] = [], repo: CacheRepoID? = nil,
                       scopes: [String]? = nil, version: String = "v1") -> String? {
        CacheIndex(entries: entries)
            .match(repo: repo ?? repoA, readScopes: scopes ?? [main], key: key, restoreKeys: restoreKeys, version: version)?
            .id
    }

    @Test("an exact key beats a newer prefix match")
    func exactBeatsPrefix() {
        let exact = entry("npm-abc", age: 100)
        let newer = entry("npm-abcdef", age: 1)
        #expect(match([newer, exact], key: "npm-abc") == exact.id)
    }

    @Test("the primary key is also tried as a prefix before the restore keys")
    func primaryKeyPrefix() {
        let prefixed = entry("npm-abc-1")
        let restore = entry("npm-zzz")
        #expect(match([restore, prefixed], key: "npm-abc", restoreKeys: ["npm-"]) == prefixed.id)
    }

    @Test("restore keys are tried in order")
    func restoreKeysInOrder() {
        let second = entry("deps-linux")
        let first = entry("deps-mac")
        #expect(match([second, first], key: "miss", restoreKeys: ["deps-mac", "deps-"]) == first.id)
    }

    @Test("the newest of several prefix matches wins")
    func newestPrefix() {
        let old = entry("deps-1", age: 50)
        let newest = entry("deps-2", age: 1)
        let middle = entry("deps-3", age: 10)
        #expect(match([old, newest, middle], key: "miss", restoreKeys: ["deps-"]) == newest.id)
    }

    @Test("the version must match exactly")
    func versionMustMatch() {
        let other = entry("deps", version: "v2")
        #expect(match([other], key: "deps") == nil)
        #expect(match([other], key: "deps", version: "v2") == other.id)
    }

    @Test("repo A never sees repo B's entries")
    func repoIsolation() {
        let theirs = entry("deps", repo: repoB)
        #expect(match([theirs], key: "deps", restoreKeys: ["d"]) == nil)
    }

    @Test("a scope that wasn't granted is invisible")
    func ungrantedScope() {
        let other = entry("deps", scope: feature)
        #expect(match([other], key: "deps", scopes: [main]) == nil)
    }

    @Test("earlier scopes win, even over an exact key in a later scope")
    func scopeOrder() {
        let onFeature = entry("deps-1", scope: feature)
        let onMain = entry("deps", scope: main)
        #expect(match([onMain, onFeature], key: "deps", scopes: [feature, main]) == onFeature.id)
    }
}
