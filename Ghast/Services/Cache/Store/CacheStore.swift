import CryptoKit
import Foundation
import os

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
    static let defaultCapBytes: Int64 = 50 * 1_000_000_000
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "cache")

    private let root: URL
    private let clock: any AppClock
    private let randomness: any CacheRandomness
    private let writer: any CacheBlobWriting
    private let indexWriter: any CacheIndexWriting
    let timing: CacheTiming
    /// The size cap applied after each finalize.
    private var capBytes: Int64
    /// Bytes pending uploads hold on disk, limited to `capBytes` across all uploads.
    private let budget: CacheByteBudget

    private var index: CacheIndex
    private var uploads: [String: PendingUpload] = [:]
    /// Part writers in use, per upload; cancelled when their upload is dropped.
    private var activeWriters: [String: [CachePartWriter]] = [:]
    private var nextCommitToken = 0
    /// `lastUsedAt` changes from restores, saved with the next index write.
    private var isIndexDirty = false

    private var indexURL: URL { root.appendingPathComponent(Self.indexFileName) }
    private var blobsURL: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    private var uploadsURL: URL { root.appendingPathComponent("uploads", isDirectory: true) }

    init(root: URL, clock: any AppClock, randomness: any CacheRandomness, writer: any CacheBlobWriting,
         indexWriter: any CacheIndexWriting = AtomicIndexWriter(), timing: CacheTiming = CacheTiming(),
         capBytes: Int64 = CacheStore.defaultCapBytes) throws {
        self.root = root
        self.capBytes = capBytes
        budget = CacheByteBudget(limit: capBytes)
        self.clock = clock
        self.randomness = randomness
        self.writer = writer
        self.indexWriter = indexWriter
        self.timing = timing
        for folder in [root, root.appendingPathComponent("blobs"), root.appendingPathComponent("uploads")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        index = Self.loadIndex(root: root)
    }

    /// A missing index is an empty cache. An unreadable one is treated the same: its archives
    /// become unnamed files, which the sweep removes. Entries whose archive is gone are dropped
    /// (the next index write records that).
    private static func loadIndex(root: URL) -> CacheIndex {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(indexFileName)),
              let saved = try? JSONDecoder().decode(CacheIndex.self, from: data)
        else { return CacheIndex() }
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let present = saved.entries.filter {
            FileManager.default.fileExists(atPath: blobs.appendingPathComponent($0.downloadID).path)
        }
        return CacheIndex(entries: present)
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

    /// The largest archive the cache accepts; a part larger than this can never be saved.
    func capacityBytes() -> Int64 { capBytes }

    /// The pending upload `uploadID` names, if any.
    func pendingUpload(_ uploadID: String) -> PendingUpload? { uploads[uploadID] }

    /// Starts (or restarts) one part with an empty file and returns its writer. The caller
    /// writes the body through it, off this actor, then calls `finishPart` or `abandonPart`.
    /// A part has one writer at a time: a newer one cancels the one still writing, whose bytes
    /// go to the replaced (unlinked) file and stay in its budget until it finishes or abandons.
    func beginPart(uploadID: String, part: CacheUploadPart) throws -> CachePartWriter {
        guard var upload = uploads[uploadID] else { throw CacheStoreError.unknownUpload }
        guard upload.commitToken == nil else { throw CacheStoreError.commitInProgress }
        supersedeWriters(uploadID, part)
        let sink: any CacheFileSink
        do {
            sink = try writer.create(partURL(uploadID, part))
        } catch {
            throw abort(uploadID, error)
        }
        budget.take(partKey(uploadID, part))  // the part's file was just replaced
        let partWriter = CachePartWriter(uploadID: uploadID, part: part, sink: sink, clock: clock, budget: budget)
        activeWriters[uploadID, default: []].append(partWriter)
        upload.markIncomplete(part)
        upload.lastActivityAt = clock.now()
        uploads[uploadID] = upload
        return partWriter
    }

    /// Ends a part whose body was written in full. A write error during it drops the upload.
    func finishPart(_ partWriter: CachePartWriter) throws {
        release(partWriter)
        let written = budget.take(partWriter.budgetKey)
        var closeError: String?
        do { try partWriter.close() } catch { closeError = String(describing: error) }
        guard var upload = uploads[partWriter.uploadID], !partWriter.wasCancelled else {
            throw CacheStoreError.unknownUpload
        }
        if let failure = partWriter.writeFailure ?? closeError {
            discard(partWriter.uploadID)
            throw CacheStoreError.writeFailed(failure)
        }
        upload.markComplete(partWriter.part)
        upload.lastActivityAt = clock.now()
        uploads[partWriter.uploadID] = upload
        let key = partKey(partWriter.uploadID, partWriter.part)
        budget.take(key)
        budget.add(key, written)
    }

    /// Ends a part whose request stopped early (or went over the budget). Its file is removed
    /// unless a retry of the same part is already writing it; the part stays incomplete and
    /// can be retried.
    func abandonPart(_ partWriter: CachePartWriter) {
        release(partWriter)
        budget.take(partWriter.budgetKey)
        try? partWriter.close()
        let isRetried = activeWriters[partWriter.uploadID]?.contains { $0.part == partWriter.part } == true
        if !isRetried, !partWriter.wasCancelled {
            try? FileManager.default.removeItem(at: partURL(partWriter.uploadID, partWriter.part))
        }
    }

    /// Builds the archive from blocks in the order given; every block must be complete. The
    /// copy runs off this actor; if the upload was dropped meanwhile (clear, sweep) the result
    /// is discarded. Block files are deleted once the archive is built, and kept until then so
    /// a failed commit can be retried.
    func commitBlocks(uploadID: String, order: [String]) async throws {
        let job = try beginCommit(uploadID: uploadID, order: order)
        let outcome: Result<Void, Error>
        do {
            try await Self.concatenate(job.sources, into: job.sink, limit: job.projectedBytes)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try endCommit(job, outcome: outcome)
    }

    private struct CommitJob: Sendable {
        let uploadID: String
        let token: Int
        let sources: [URL]
        let projectedBytes: Int64
        let sink: any CacheFileSink
    }

    private func beginCommit(uploadID: String, order: [String]) throws -> CommitJob {
        guard var upload = uploads[uploadID] else { throw CacheStoreError.unknownUpload }
        guard upload.commitToken == nil else { throw CacheStoreError.commitInProgress }
        if let missing = order.first(where: { !upload.completedBlocks.contains($0) }) {
            throw CacheStoreError.missingBlock(id: missing)
        }
        if let duplicate = Self.firstDuplicate(order) {
            throw CacheStoreError.duplicateBlock(id: duplicate)
        }
        for unlisted in upload.completedBlocks.subtracting(order) {
            try? FileManager.default.removeItem(at: partURL(uploadID, .block(id: unlisted)))
            budget.take(partKey(uploadID, .block(id: unlisted)))
            upload.completedBlocks.remove(unlisted)
        }
        uploads[uploadID] = upload
        // The archive replaces the blocks in the budget, so the projection only has to fit the
        // cap and the budget as it stands (a lowered cap can leave it over).
        let projected = order.reduce(Int64(0)) { $0 + budget.bytes(partKey(uploadID, .block(id: $1))) }
        guard projected <= capBytes, budget.total <= budget.limit else {
            discard(uploadID)
            throw CacheStoreError.tooLarge(sizeBytes: projected, capBytes: capBytes)
        }
        let sink: any CacheFileSink
        do {
            sink = try writer.create(partURL(uploadID, .whole))
        } catch {
            throw abort(uploadID, error)
        }
        budget.take(partKey(uploadID, .whole))
        for id in order { budget.add(partKey(uploadID, .whole), budget.take(partKey(uploadID, .block(id: id)))) }
        nextCommitToken += 1
        upload.commitToken = nextCommitToken
        upload.hasWhole = false
        upload.lastActivityAt = clock.now()
        uploads[uploadID] = upload
        return CommitJob(uploadID: uploadID, token: nextCommitToken,
                         sources: order.map { partURL(uploadID, .block(id: $0)) }, projectedBytes: projected, sink: sink)
    }

    private func endCommit(_ job: CommitJob, outcome: Result<Void, Error>) throws {
        guard var upload = uploads[job.uploadID], upload.commitToken == job.token else {
            if uploads[job.uploadID] == nil { budget.releaseUpload(job.uploadID) }
            throw CacheStoreError.unknownUpload
        }
        if case .failure(let error) = outcome {
            if let error = error as? CacheStoreError, case .tooLarge = error {
                discard(job.uploadID)
                throw error
            }
            throw abort(job.uploadID, error)
        }
        for block in upload.completedBlocks {
            try? FileManager.default.removeItem(at: partURL(job.uploadID, .block(id: block)))
        }
        upload.completedBlocks = []
        upload.commitToken = nil
        upload.hasWhole = true
        upload.lastActivityAt = clock.now()
        uploads[job.uploadID] = upload
    }

    private static let copyChunkSize = 8 << 20

    /// Appends each source to `sink` in large chunks, deleting each source once copied, then
    /// closes it. Never writes more than `limit` bytes. Runs off the actor.
    @concurrent
    private nonisolated static func concatenate(_ sources: [URL], into sink: any CacheFileSink, limit: Int64) async throws {
        defer { try? sink.close() }
        var copied: Int64 = 0
        for source in sources {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: copyChunkSize), !chunk.isEmpty {
                copied += Int64(chunk.count)
                guard copied <= limit else { throw CacheStoreError.tooLarge(sizeBytes: copied, capBytes: limit) }
                try sink.write(chunk)
            }
            try? FileManager.default.removeItem(at: source)
        }
        try sink.close()
    }

    private static func firstDuplicate(_ ids: [String]) -> String? {
        var seen: Set<String> = []
        return ids.first { !seen.insert($0).inserted }
    }

    /// Cancels the writers still writing `part`; they stop counting as its writers at once.
    private func supersedeWriters(_ uploadID: String, _ part: CacheUploadPart) {
        let superseded = activeWriters[uploadID]?.filter { $0.part == part } ?? []
        guard !superseded.isEmpty else { return }
        superseded.forEach { $0.cancel() }
        activeWriters[uploadID]?.removeAll { $0.part == part }
    }

    private func release(_ partWriter: CachePartWriter) {
        activeWriters[partWriter.uploadID]?.removeAll { $0 === partWriter }
        if activeWriters[partWriter.uploadID]?.isEmpty == true { activeWriters[partWriter.uploadID] = nil }
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
        guard actual <= capBytes else {
            discard(uploadID)
            throw CacheStoreError.tooLarge(sizeBytes: actual, capBytes: capBytes)
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
        do {
            try evict(capBytes: capBytes)
        } catch {
            // The entry is saved; the cap is applied again by the next finalize or sweep.
            Self.logger.error("Cache eviction after a save failed: \(String(describing: error), privacy: .public)")
        }
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
        let (savedIndex, savedUploads) = (index, uploads)
        index = CacheIndex()
        uploads = [:]
        do {
            try saveIndex()
        } catch {
            (index, uploads) = (savedIndex, savedUploads)
            throw error
        }
        activeWriters.values.joined().forEach { $0.cancel() }
        activeWriters = [:]
        budget.releaseAll()
        try Self.emptyFolder(blobsURL)
        try Self.emptyFolder(uploadsURL)
    }

    /// Saves the index if restores changed it since the last write.
    func flush() throws {
        if isIndexDirty { try saveIndex() }
    }

    // MARK: Eviction and expiry

    /// Changes the cap and applies it now.
    func setCapBytes(_ bytes: Int64) throws {
        capBytes = bytes
        budget.setLimit(bytes)
        try evict(capBytes: bytes)
    }

    /// Removes the least recently used entries until the total is at most `capBytes`.
    func evict(capBytes: Int64) throws {
        var total = index.totalBytes
        var doomed: Set<String> = []
        for entry in index.entries.sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) where total > capBytes {
            doomed.insert(entry.id)
            total -= entry.sizeBytes
        }
        try remove(entryIDs: doomed)
    }

    /// Removes entries unused for longer than `timing.entryExpiry`, uploads idle for longer
    /// than `timing.uploadIdle`, and files no entry or upload names (left by a crash).
    func sweep() throws {
        let now = clock.now()
        let expired = index.entries.filter { now.timeIntervalSince($0.lastUsedAt) > timing.entryExpiry }
        try remove(entryIDs: Set(expired.map(\.id)))
        for (uploadID, upload) in uploads where now.timeIntervalSince(lastActivity(uploadID, upload)) > timing.uploadIdle {
            discard(uploadID)
        }
        try flush()
        try Self.removeUnnamed(in: blobsURL, keeping: Set(index.entries.map(\.downloadID)))
        try Self.removeUnnamed(in: uploadsURL, keeping: Set(uploads.keys))
    }

    /// Drops entries from the index (saved first), then deletes their archives. A download
    /// already reading an archive keeps its open file; POSIX frees it when the reader closes.
    private func remove(entryIDs: Set<String>) throws {
        guard !entryIDs.isEmpty else { return }
        let before = index
        let removed = index.entries.filter { entryIDs.contains($0.id) }
        index.entries.removeAll { entryIDs.contains($0.id) }
        do {
            try saveIndex()
        } catch {
            index = before
            throw error
        }
        for entry in removed {
            try? FileManager.default.removeItem(at: blobsURL.appendingPathComponent(entry.downloadID))
        }
    }

    // MARK: Helpers

    private func saveIndex() throws {
        do {
            try indexWriter.write(JSONEncoder().encode(index), to: indexURL)
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

    /// The later of the upload's own activity and its writers' last writes.
    private func lastActivity(_ uploadID: String, _ upload: PendingUpload) -> Date {
        ((activeWriters[uploadID] ?? []).map(\.lastActivity) + [upload.lastActivityAt]).max() ?? upload.lastActivityAt
    }

    private func discard(_ uploadID: String) {
        activeWriters.removeValue(forKey: uploadID)?.forEach { $0.cancel() }
        uploads[uploadID] = nil
        budget.releaseUpload(uploadID)
        try? FileManager.default.removeItem(at: uploadFolder(uploadID))
    }

    private func partKey(_ uploadID: String, _ part: CacheUploadPart) -> CacheByteBudget.Key {
        .init(uploadID: uploadID, holder: .part(part))
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



    private static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? -1
    }

    private static func removeUnnamed(in folder: URL, keeping names: Set<String>) throws {
        let manager = FileManager.default
        for item in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where !names.contains(item.lastPathComponent) {
            try manager.removeItem(at: item)
        }
    }

    private static func emptyFolder(_ folder: URL) throws {
        let manager = FileManager.default
        for item in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: item)
        }
    }
}
