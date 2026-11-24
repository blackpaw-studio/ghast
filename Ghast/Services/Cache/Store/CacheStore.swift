import CryptoKit
import Foundation

/// The cache on disk: `index.json` (finalized entries, written atomically), `blobs/<downloadID>`
/// (archives) and `uploads/<uploadID>/` (uploads in progress). File names are always random hex
/// IDs or hashes, never keys or client-supplied block IDs.
///
/// Every method is synchronous inside the actor, so each runs to completion before the next
/// one starts. Crash safety comes from ordering: a finalize moves the archive into `blobs/`
/// before the index names it, and a removal drops the entry from the index before deleting
/// its file, so a crash leaves at worst an unnamed file for the sweep to reclaim.
actor CacheStore {
    static let indexFileName = "index.json"

    private let root: URL
    private let clock: any AppClock
    private let randomness: any CacheRandomness
    private let writer: any CacheBlobWriting
    let timing: CacheTiming

    private var index: CacheIndex
    private var uploads: [String: PendingUpload] = [:]
    /// `lastUsedAt` changes from restores, saved with the next index write.
    private var isIndexDirty = false

    private var indexURL: URL { root.appendingPathComponent(Self.indexFileName) }
    private var blobsURL: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    private var uploadsURL: URL { root.appendingPathComponent("uploads", isDirectory: true) }

    init(root: URL, clock: any AppClock, randomness: any CacheRandomness, writer: any CacheBlobWriting,
         timing: CacheTiming = CacheTiming()) throws {
        self.root = root
        self.clock = clock
        self.randomness = randomness
        self.writer = writer
        self.timing = timing
        for folder in [root, root.appendingPathComponent("blobs"), root.appendingPathComponent("uploads")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        index = Self.loadIndex(at: root.appendingPathComponent(Self.indexFileName))
    }

    /// A missing index is an empty cache. An unreadable one is treated the same: its archives
    /// become unnamed files, which the sweep removes.
    private static func loadIndex(at url: URL) -> CacheIndex {
        guard let data = try? Data(contentsOf: url) else { return CacheIndex() }
        return (try? JSONDecoder().decode(CacheIndex.self, from: data)) ?? CacheIndex()
    }

    // MARK: Uploads

    /// Reserves an upload for a key and version in a scope. Nil when that slot already has an
    /// entry or an upload in progress (the client then skips its save).
    func reserve(repo: CacheRepoID, scope: String, key: String, version: String) throws -> CacheReservation? {
        let taken = index.entries.contains { $0.isSlot(repo: repo, scope: scope, key: key, version: version) }
            || uploads.values.contains { $0.isSlot(repo: repo, scope: scope, key: key, version: version) }
        guard !taken else { return nil }
        let reservation = CacheReservation(uploadID: randomness.id128(), signature: randomness.signature())
        try FileManager.default.createDirectory(at: uploadFolder(reservation.uploadID), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        uploads[reservation.uploadID] = PendingUpload(repo: repo, scope: scope, key: key, version: version,
                                                      signature: reservation.signature, lastActivityAt: clock.now())
        return reservation
    }

    /// The pending upload `uploadID` names, if any.
    func pendingUpload(_ uploadID: String) -> PendingUpload? { uploads[uploadID] }

    /// Starts (or restarts) one part of an upload with an empty file.
    func beginPart(uploadID: String, part: CacheUploadPart) throws {
        guard var upload = uploads[uploadID] else { throw CacheStoreError.unknownUpload }
        let url = partURL(uploadID, part)
        try? FileManager.default.removeItem(at: url)
        do {
            try writer.append(EmptyCollection<UInt8>(), to: url)
        } catch {
            throw abort(uploadID, error)
        }
        switch part {
        case .whole: upload.hasWhole = true
        case .block(let id): upload.startedBlocks.insert(id)
        }
        upload.lastActivityAt = clock.now()
        uploads[uploadID] = upload
    }

    /// Appends bytes to a started part. A write error drops the whole upload, files included.
    func appendPart(uploadID: String, part: CacheUploadPart, bytes: some Collection<UInt8> & Sendable) throws {
        guard var upload = uploads[uploadID] else { throw CacheStoreError.unknownUpload }
        guard Self.isStarted(part, in: upload) else { throw CacheStoreError.partNotStarted }
        do {
            try writer.append(bytes, to: partURL(uploadID, part))
        } catch {
            throw abort(uploadID, error)
        }
        upload.lastActivityAt = clock.now()
        uploads[uploadID] = upload
    }

    /// Builds the archive from blocks in the order given. Every block must have been uploaded.
    func commitBlocks(uploadID: String, order: [String]) throws {
        guard var upload = uploads[uploadID] else { throw CacheStoreError.unknownUpload }
        if let missing = order.first(where: { !upload.startedBlocks.contains($0) }) {
            throw CacheStoreError.missingBlock(id: missing)
        }
        let whole = partURL(uploadID, .whole)
        try? FileManager.default.removeItem(at: whole)
        do {
            try writer.append(EmptyCollection<UInt8>(), to: whole)
            for block in order {
                try copy(partURL(uploadID, .block(id: block)), appendingTo: whole)
            }
        } catch {
            throw abort(uploadID, error)
        }
        upload.hasWhole = true
        upload.lastActivityAt = clock.now()
        uploads[uploadID] = upload
    }

    /// Makes the upload for this slot an entry. The archive must be exactly `sizeBytes`;
    /// otherwise the upload is dropped.
    func finalize(repo: CacheRepoID, scope: String, key: String, version: String, sizeBytes: Int64) throws -> CacheEntry {
        guard let (uploadID, upload) = uploads.first(where: { $0.value.isSlot(repo: repo, scope: scope, key: key, version: version) })
        else { throw CacheStoreError.unknownUpload }
        guard upload.hasWhole else {
            discard(uploadID)
            throw CacheStoreError.nothingUploaded
        }
        let source = partURL(uploadID, .whole)
        let actual = Self.fileSize(source)
        guard actual == sizeBytes else {
            discard(uploadID)
            throw CacheStoreError.sizeMismatch(expected: sizeBytes, actual: actual)
        }
        let now = clock.now()
        let entry = CacheEntry(id: uploadID, repo: repo, scope: scope, key: key, version: version, sizeBytes: actual,
                               createdAt: now, lastUsedAt: now, downloadID: randomness.id128())
        let blob = blobsURL.appendingPathComponent(entry.downloadID)
        do {
            try FileManager.default.moveItem(at: source, to: blob)
        } catch {
            throw abort(uploadID, error)
        }
        index.entries.append(entry)
        do {
            try saveIndex()
        } catch {
            index.entries.removeLast()
            try? FileManager.default.removeItem(at: blob)
            discard(uploadID)
            throw error
        }
        discard(uploadID)
        return entry
    }

    // MARK: Restores

    /// The entry a restore gets (see `CacheIndex.match`), marked as used now.
    func lookup(repo: CacheRepoID, readScopes: [String], key: String, restoreKeys: [String], version: String) -> CacheEntry? {
        guard let found = index.match(repo: repo, readScopes: readScopes, key: key, restoreKeys: restoreKeys, version: version),
              let position = index.entries.firstIndex(where: { $0.id == found.id })
        else { return nil }
        index.entries[position].lastUsedAt = clock.now()
        isIndexDirty = true
        return index.entries[position]
    }

    /// Where the archive for `downloadID` is, when an entry names it.
    func blobURL(downloadID: String) -> URL? {
        guard index.entries.contains(where: { $0.downloadID == downloadID }) else { return nil }
        return blobsURL.appendingPathComponent(downloadID)
    }

    // MARK: Housekeeping

    func usage() -> CacheUsage {
        CacheUsage(entryCount: index.entries.count, totalBytes: index.totalBytes, pendingUploads: uploads.count)
    }

    /// Removes every entry and every upload in progress.
    func clear() throws {
        index = CacheIndex()
        uploads = [:]
        try saveIndex()
        try Self.emptyFolder(blobsURL)
        try Self.emptyFolder(uploadsURL)
    }

    /// Saves the index if restores changed it since the last write.
    func flush() throws {
        if isIndexDirty { try saveIndex() }
    }

    // MARK: Helpers

    private func saveIndex() throws {
        do {
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
            isIndexDirty = false
        } catch {
            throw CacheStoreError.indexWriteFailed(String(describing: error))
        }
    }

    /// Drops an upload after a write error and returns the error to throw.
    private func abort(_ uploadID: String, _ error: Error) -> CacheStoreError {
        discard(uploadID)
        return CacheStoreError.writeFailed(String(describing: error))
    }

    private func discard(_ uploadID: String) {
        uploads[uploadID] = nil
        try? FileManager.default.removeItem(at: uploadFolder(uploadID))
    }

    private func uploadFolder(_ uploadID: String) -> URL {
        uploadsURL.appendingPathComponent(uploadID, isDirectory: true)
    }

    /// A block's file is named by the SHA-256 of its ID, so no client string reaches a path.
    private func partURL(_ uploadID: String, _ part: CacheUploadPart) -> URL {
        switch part {
        case .whole:
            return uploadFolder(uploadID).appendingPathComponent("archive")
        case .block(let id):
            let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            return uploadFolder(uploadID).appendingPathComponent("block-\(name)")
        }
    }

    private static func isStarted(_ part: CacheUploadPart, in upload: PendingUpload) -> Bool {
        switch part {
        case .whole: upload.hasWhole
        case .block(let id): upload.startedBlocks.contains(id)
        }
    }

    private static let copyChunkSize = 1 << 20

    private func copy(_ source: URL, appendingTo destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: Self.copyChunkSize), !chunk.isEmpty {
            try writer.append(chunk, to: destination)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? -1
    }

    private static func emptyFolder(_ folder: URL) throws {
        let manager = FileManager.default
        for item in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: item)
        }
    }
}
