import Darwin
import Foundation
@testable import Ghast

/// Real files, plus a record of every sink: its inode, bytes written and whether it is closed.
/// `uploadDiskBytes` counts what upload files really hold on disk, including files that were
/// unlinked while a sink still had them open (which a directory listing can't see).
final class AccountingBlobWriter: CacheBlobWriting, @unchecked Sendable {
    private final class Record: @unchecked Sendable {
        let inode: UInt64
        var written: Int64 = 0
        var isClosed = false
        init(inode: UInt64) { self.inode = inode }
    }

    private final class Sink: CacheFileSink, @unchecked Sendable {
        let real: any CacheFileSink
        let record: Record
        let lock: NSLock
        init(real: any CacheFileSink, record: Record, lock: NSLock) { (self.real, self.record, self.lock) = (real, record, lock) }

        func write(_ bytes: some Collection<UInt8>) throws {
            try real.write(bytes)
            lock.withLock { record.written += Int64(bytes.count) }
        }

        func close() throws {
            try real.close()
            lock.withLock { record.isClosed = true }
        }
    }

    private let lock = NSLock()
    private var records: [Record] = []

    func create(_ url: URL) throws -> any CacheFileSink {
        let real = try FileBlobWriter().create(url)
        let record = Record(inode: Self.inode(url) ?? 0)
        lock.withLock { records.append(record) }
        return Sink(real: real, record: record, lock: lock)
    }

    /// Bytes upload files hold: every file under `root/uploads`, and every still-open sink whose
    /// file is no longer there.
    func uploadDiskBytes(root: URL) -> Int64 {
        let uploads = root.appendingPathComponent("uploads")
        let files = (FileManager.default.enumerator(at: uploads, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        var onDisk: [UInt64: Int64] = [:]
        for file in files {
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            onDisk[UInt64(info.st_ino)] = Int64(info.st_size)
        }
        let unlinkedOpen = lock.withLock {
            records.filter { !$0.isClosed && onDisk[$0.inode] == nil }.reduce(Int64(0)) { $0 + $1.written }
        }
        return onDisk.values.reduce(0, +) + unlinkedOpen
    }

    private static func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }
}
