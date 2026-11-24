import Foundation

/// A reserved upload: where the archive goes and the secret its URL carries.
struct CacheReservation: Equatable, Sendable {
    let uploadID: String
    let signature: String
}

/// One part of an upload: the whole archive in one PUT, or one block of a block upload.
enum CacheUploadPart: Hashable, Sendable {
    case whole
    case block(id: String)
}

/// Space the cache uses.
struct CacheUsage: Equatable, Sendable {
    let entryCount: Int
    let totalBytes: Int64
    let pendingUploads: Int
}

enum CacheStoreError: Error, Equatable {
    case unknownUpload
    case partNotStarted
    case missingBlock(id: String)
    case nothingUploaded
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The archive is larger than the whole cache may be.
    case tooLarge(sizeBytes: Int64, capBytes: Int64)
    case writeFailed(String)
    case indexWriteFailed(String)
}

/// An upload in progress, held in memory only; leftovers on disk from an earlier run are
/// removed by the sweep.
struct PendingUpload: Sendable {
    let repo: CacheRepoID
    let scope: String
    let key: String
    let version: String
    let signature: String
    var lastActivityAt: Date
    var startedBlocks: Set<String> = []
    var hasWhole = false

    func isSlot(repo: CacheRepoID, scope: String, key: String, version: String) -> Bool {
        self.repo == repo && self.scope == scope && self.key == key && self.version == version
    }
}
