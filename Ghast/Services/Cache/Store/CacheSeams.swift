import Foundation

/// Random upload and download IDs and upload signatures.
protocol CacheRandomness: Sendable {
    /// 128 random bits as lowercase hex; safe as a file name.
    func id128() -> String
    /// A per-upload secret for the `sig` query parameter, base64url.
    func signature() -> String
}

/// `SystemRandomNumberGenerator` is a cryptographically secure generator on Apple platforms.
struct SystemCacheRandomness: CacheRandomness {
    func id128() -> String {
        Self.bytes(16).map { String(format: "%02x", $0) }.joined()
    }

    func signature() -> String {
        Data(Self.bytes(32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// An open file that bytes are appended to. Closing twice is harmless.
protocol CacheFileSink: AnyObject, Sendable {
    func write(_ bytes: some Collection<UInt8>) throws
    func close() throws
}

/// Creates archive files. Injected so tests can fail a write (for example with `ENOSPC`) or
/// hold one.
protocol CacheBlobWriting: Sendable {
    /// Creates `url` empty and owner-only (replacing any file there) and opens it for writing.
    func create(_ url: URL) throws -> any CacheFileSink
}

struct FileBlobWriter: CacheBlobWriting {
    func create(_ url: URL) throws -> any CacheFileSink {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileSink(handle: try FileHandle(forWritingTo: url))
    }
}

/// One open `FileHandle`; writes from one part at a time, so the lock only guards close.
final class FileSink: CacheFileSink, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(handle: FileHandle) { self.handle = handle }

    deinit { try? handle?.close() }

    func write(_ bytes: some Collection<UInt8>) throws {
        guard let handle = lock.withLock({ self.handle }) else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: Data(bytes))
    }

    func close() throws {
        let open = lock.withLock { () -> FileHandle? in
            defer { handle = nil }
            return handle
        }
        try open?.close()
    }
}

/// Writes the index file. Injected so tests can fail a write.
protocol CacheIndexWriting: Sendable {
    func write(_ data: Data, to url: URL) throws
}

/// Writes through a temporary file and a rename, so a reader sees the old or the new index.
struct AtomicIndexWriter: CacheIndexWriting {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

/// How long things live in the cache.
struct CacheTiming: Sendable {
    /// An upload with no write for this long is dropped.
    var uploadIdle: TimeInterval = 10 * 60
    /// An entry nobody restored for longer than this is removed.
    var entryExpiry: TimeInterval = 7 * 24 * 60 * 60
    /// How often the sweeper runs.
    var sweepInterval: Duration = .seconds(60 * 60)
}
