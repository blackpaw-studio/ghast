import Foundation
@testable import Ghast

/// Resolves tags from a fixed map of `host/repository:tag` to digest.
struct FakeTartCacheLinks: TartCacheLinkReading {
    var digests: [String: String] = [:]

    func digest(forTag tag: TartImageRef) -> String? { digests[tag.reference] }
}
