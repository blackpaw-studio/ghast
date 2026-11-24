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
    /// Each pending upload's files; every file owns its share of the budget.
    private var files: [String: UploadFiles] = [:]
    /// Discarded files whose last write or read was still in flight; each removes itself and
    /// releases its bytes when that ends.
    private var closing: [CacheUploadFile] = []
    private var nextFileNumber = 0
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

    /// Bytes pending uploads hold against the budget.
    func uploadBytesCharged() -> Int64 { budget.total }

    /// The pending upload `uploadID` names, if any.
    func pendingUpload(_ uploadID: String) -> PendingUpload? { uploads[uploadID] }

    /// Starts (or restarts) one part in a new file and returns its writer. The caller writes
    /// the body through it, off this actor, then calls `finishPart` or `abandonPart`. A part
    /// has one writer at a time: a newer one closes the older writer and discards its file, and
    /// a restarted part drops the finished file it replaces.
    func beginPart(uploadID: String, part: CacheUploadPart) throws -> CachePartWriter {
        defer { auditBudget() }
        guard var upload = uploads[uploadID] else { throw CacheStoreError.unknownUpload }
        guard upload.commitToken == nil else { throw CacheStoreError.commitInProgress }
        var tracked = files[uploadID] ?? UploadFiles()
        tracked.writers.removeValue(forKey: part).map { retire($0.file) }
        tracked.removeFinished(part).map(retire)
        files[uploadID] = tracked
        upload.markIncomplete(part)
        upload.lastActivityAt = clock.now()
        uploads[uploadID] = upload
        let file = try makeFile(uploadID, part)
        let partWriter = CachePartWriter(uploadID: uploadID, part: part, file: file, clock: clock, budget: budget)
        files[uploadID]?.writers[part] = partWriter
        return partWriter
    }

    /// Ends a part whose body was written in full. A write error during it drops the upload.
    func finishPart(_ partWriter: CachePartWriter) throws {
        defer { auditBudget() }
        guard var upload = uploads[partWriter.uploadID], var tracked = files[partWriter.uploadID],
              tracked.writers[partWriter.part] === partWriter
        else {
            retire(partWriter.file)  // superseded, or its upload was dropped
            throw CacheStoreError.unknownUpload
        }
        tracked.writers[partWriter.part] = nil
        files[partWriter.uploadID] = tracked
        var closeError: String?
        do { try partWriter.file.close() } catch { closeError = String(describing: error) }
        if let failure = partWriter.writeFailure ?? closeError {
            retire(partWriter.file)
            discard(partWriter.uploadID)
            throw CacheStoreError.writeFailed(failure)
        }
        tracked.setFinished(partWriter.part, partWriter.file)
        files[partWriter.uploadID] = tracked
        upload.markComplete(partWriter.part)
        upload.lastActivityAt = clock.now()
        uploads[partWriter.uploadID] = upload
    }

    /// Ends a part whose request stopped early (or went over the budget): its file is
    /// discarded and the part stays incomplete, so it can be retried.
    func abandonPart(_ partWriter: CachePartWriter) {
        defer { auditBudget() }
        if files[partWriter.uploadID]?.writers[partWriter.part] === partWriter {
            files[partWriter.uploadID]?.writers[partWriter.part] = nil
        }
        retire(partWriter.file)
    }

    /// Builds the archive from blocks in the order given; every block must be complete. The
    /// copy runs off this actor; if the upload was dropped meanwhile (clear, sweep) the result
    /// is discarded. Each block file is deleted once copied, and all are kept until the copy
    /// starts so a refused commit can be retried.
    func commitBlocks(uploadID: String, order: [String]) async throws {
        let job = try beginCommit(uploadID: uploadID, order: order)
        let outcome: Result<Void, Error>
        do {
            try await Self.concatenate(job.sources, into: job.archive, limit: job.projectedBytes)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try endCommit(job, outcome: outcome)
    }

    private struct CommitJob: Sendable {
        let uploadID: String
        let token: Int
        let sources: [CacheUploadFile]
        let projectedBytes: Int64
        let archive: CacheUploadFile
    }

    private func beginCommit(uploadID: String, order: [String]) throws -> CommitJob {
        defer { auditBudget() }
        guard var upload = uploads[uploadID], var tracked = files[uploadID] else { throw CacheStoreError.unknownUpload }
        guard upload.commitToken == nil else { throw CacheStoreError.commitInProgress }
        if let missing = order.first(where: { tracked.blocks[$0] == nil }) {
            throw CacheStoreError.missingBlock(id: missing)
        }
        if let duplicate = Self.firstDuplicate(order) {
            throw CacheStoreError.duplicateBlock(id: duplicate)
        }
        for unlisted in Set(tracked.blocks.keys).subtracting(order) {
            tracked.blocks.removeValue(forKey: unlisted).map(retire)
            upload.completedBlocks.remove(unlisted)
        }
        files[uploadID] = tracked
        uploads[uploadID] = upload
        let sources = order.compactMap { tracked.blocks[$0] }
        // Copying charges the archive as it grows and frees each block once copied, so the
        // copy needs room for the largest block on top of what the budget holds now.
        let projected = sources.reduce(Int64(0)) { $0 + $1.charged }
        let largest = sources.map(\.charged).max() ?? 0
        guard projected <= capBytes, budget.total + largest <= budget.limit else {
            discard(uploadID)
            throw CacheStoreError.tooLarge(sizeBytes: projected, capBytes: capBytes)
        }
        tracked.whole.map(retire)
        tracked.whole = nil
        files[uploadID] = tracked
        let archive = try makeFile(uploadID, .whole)
        files[uploadID]?.archive = archive
        nextCommitToken += 1
        upload.commitToken = nextCommitToken
        upload.hasWhole = false
        upload.lastActivityAt = clock.now()
        uploads[uploadID] = upload
        return CommitJob(uploadID: uploadID, token: nextCommitToken, sources: sources, projectedBytes: projected, archive: archive)
    }

    private func endCommit(_ job: CommitJob, outcome: Result<Void, Error>) throws {
        defer { auditBudget() }
        guard var upload = uploads[job.uploadID], upload.commitToken == job.token, var tracked = files[job.uploadID] else {
            retire(job.archive)
            throw CacheStoreError.unknownUpload
        }
        if case .failure(let error) = outcome {
            if let error = error as? CacheStoreError, case .tooLarge = error {
                discard(job.uploadID)
                throw error
            }
            throw abort(job.uploadID, error)
        }
        tracked.blocks.values.forEach(retire)
        tracked.blocks = [:]
        tracked.archive = nil
        tracked.whole = job.archive
        files[job.uploadID] = tracked
        upload.completedBlocks = []
        upload.commitToken = nil
        upload.hasWhole = true
        upload.lastActivityAt = clock.now()
        uploads[job.uploadID] = upload
    }

    private static let copyChunkSize = 8 << 20

    /// Appends each source to `archive` in large chunks, discarding each source once copied,
    /// then closes it. Never writes more than `limit` bytes. Runs off the actor.
    @concurrent
    private nonisolated static func concatenate(_ sources: [CacheUploadFile], into archive: CacheUploadFile, limit: Int64) async throws {
        var copied: Int64 = 0
        for source in sources {
            guard source.beginReading() else { throw CacheStoreError.unknownUpload }
            do {
                let handle = try FileHandle(forReadingFrom: source.url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: copyChunkSize), !chunk.isEmpty {
                    copied += Int64(chunk.count)
                    guard copied <= limit else { throw CacheStoreError.tooLarge(sizeBytes: copied, capBytes: limit) }
                    try appendChunk(chunk, to: archive, copied: copied, limit: limit)
                }
            } catch {
                source.endReading()
                throw error
            }
            source.endReading()
            source.discard()
        }
        try archive.close()
    }

    private nonisolated static func appendChunk(_ chunk: Data, to archive: CacheUploadFile, copied: Int64, limit: Int64) throws {
        do {
            try archive.append(chunk)
        } catch .closed {
            throw CacheStoreError.unknownUpload
        } catch .overBudget {
            throw CacheStoreError.tooLarge(sizeBytes: copied, capBytes: limit)
        } catch .write(let error) {
            throw error
        }
    }

    private static func firstDuplicate(_ ids: [String]) -> String? {
        var seen: Set<String> = []
        return ids.first { !seen.insert($0).inserted }
    }

    /// Makes the upload for this slot an entry. The archive must be exactly `sizeBytes`;
    /// otherwise the upload is dropped.
    func finalize(repo: CacheRepoID, scope: String, key: String, version: String, sizeBytes: Int64) throws -> CacheEntry {
        guard let (uploadID, upload) = uploads.first(where: { $0.value.isSlot(repo: repo, scope: scope, key: key, version: version) })
        else { throw CacheStoreError.unknownUpload }
        defer { auditBudget() }
        guard upload.hasWhole, let whole = files[uploadID]?.whole else {
            discard(uploadID)
            throw CacheStoreError.nothingUploaded
        }
        let actual = Self.fileSize(whole.url)
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
            try whole.adopt(movingTo: blob)
        } catch {
            throw abort(uploadID, error)
        }
        files[uploadID]?.whole = nil
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
        defer { auditBudget() }
        let savedIndex = index
        index = CacheIndex()
        do {
            try saveIndex()
        } catch {
            index = savedIndex
            throw error
        }
        uploads.keys.forEach(discard)
        try Self.emptyFolder(blobsURL)
        try Self.removeUnnamed(in: uploadsURL, keeping: busyUploadFolders())
    }

    /// Saves the index if restores changed it since the last write.
    func flush() throws {
        if isIndexDirty { try saveIndex() }
    }

    // MARK: Eviction and expiry

    /// Changes the cap and applies it now.
    func setCapBytes(_ bytes: Int64) throws {
        defer { auditBudget() }
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
        defer { auditBudget() }
        closing.forEach { $0.discard() }  // retries files whose removal failed
        let now = clock.now()
        let expired = index.entries.filter { now.timeIntervalSince($0.lastUsedAt) > timing.entryExpiry }
        try remove(entryIDs: Set(expired.map(\.id)))
        for (uploadID, upload) in uploads where now.timeIntervalSince(lastActivity(uploadID, upload)) > timing.uploadIdle {
            discard(uploadID)
        }
        try flush()
        try Self.removeUnnamed(in: blobsURL, keeping: Set(index.entries.map(\.downloadID)))
        try Self.removeUnnamed(in: uploadsURL, keeping: Set(uploads.keys).union(busyUploadFolders()))
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
        ((files[uploadID]?.writers.values.map(\.lastActivity) ?? []) + [upload.lastActivityAt]).max() ?? upload.lastActivityAt
    }

    /// Drops an upload: every file is discarded, and the folder goes once nothing in it is
    /// still being written or read.
    private func discard(_ uploadID: String) {
        files.removeValue(forKey: uploadID)?.all.forEach(retire)
        uploads[uploadID] = nil
        if !busyUploadFolders().contains(uploadID) {
            try? FileManager.default.removeItem(at: uploadFolder(uploadID))
        }
    }

    /// Discards a file; one whose write or read is still in flight is kept until it finishes.
    private func retire(_ file: CacheUploadFile) {
        file.discard()
        closing.removeAll(where: \.isFinished)
        if !file.isFinished, !closing.contains(where: { $0 === file }) { closing.append(file) }
    }

    /// Upload folders holding a discarded file that hasn't finished closing.
    private func busyUploadFolders() -> Set<String> {
        closing.removeAll(where: \.isFinished)
        return Set(closing.map { $0.url.deletingLastPathComponent().lastPathComponent })
    }

    /// A new file for `part`, created empty. A creation error drops the upload.
    private func makeFile(_ uploadID: String, _ part: CacheUploadPart) throws -> CacheUploadFile {
        nextFileNumber += 1
        let url = fileURL(uploadID, part, number: nextFileNumber)
        do {
            return CacheUploadFile(url: url, sink: try writer.create(url), budget: budget)
        } catch {
            throw abort(uploadID, error)
        }
    }

    /// Debug builds check that every byte the budget holds belongs to a file the store still
    /// tracks (or one still closing), so no charge outlives its file or is released twice.
    private func auditBudget() {
        #if DEBUG
        closing.removeAll(where: \.isFinished)
        let owners = Set((files.values.flatMap(\.all) + closing).map(ObjectIdentifier.init))
        assert(budget.isHeld(only: owners), "the upload budget holds bytes for a file the store no longer tracks")
        #endif
    }

    private func uploadFolder(_ uploadID: String) -> URL {
        uploadsURL.appendingPathComponent(uploadID, isDirectory: true)
    }

    /// Every file gets its own name, so a newer writer never replaces a file an older one still
    /// has open. A block's name holds the SHA-256 of its ID, so no client string reaches a path.
    private func fileURL(_ uploadID: String, _ part: CacheUploadPart, number: Int) -> URL {
        switch part {
        case .whole:
            return uploadFolder(uploadID).appendingPathComponent("archive-\(number)")
        case .block(let id):
            let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            return uploadFolder(uploadID).appendingPathComponent("block-\(name)-\(number)")
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

/// One pending upload's files.
private struct UploadFiles {
    /// The writer of each part being written.
    var writers: [CacheUploadPart: CachePartWriter] = [:]
    /// Finished blocks, by block ID.
    var blocks: [String: CacheUploadFile] = [:]
    /// The finished archive: a single-shot upload or a committed block list.
    var whole: CacheUploadFile?
    /// The archive a commit is building.
    var archive: CacheUploadFile?

    var all: [CacheUploadFile] { writers.values.map(\.file) + Array(blocks.values) + [whole, archive].compactMap { $0 } }

    /// Takes the finished file `part` names, if any.
    mutating func removeFinished(_ part: CacheUploadPart) -> CacheUploadFile? {
        switch part {
        case .whole:
            defer { whole = nil }
            return whole
        case .block(let id):
            return blocks.removeValue(forKey: id)
        }
    }

    mutating func setFinished(_ part: CacheUploadPart, _ file: CacheUploadFile) {
        switch part {
        case .whole: whole = file
        case .block(let id): blocks[id] = file
        }
    }
}
