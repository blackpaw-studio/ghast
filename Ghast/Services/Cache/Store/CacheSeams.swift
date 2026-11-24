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

/// Appends bytes to a file, creating it owner-only when missing. Injected so tests can fail a
/// write (for example with `ENOSPC`).
protocol CacheBlobWriting: Sendable {
    func append(_ bytes: some Collection<UInt8>, to url: URL) throws
}

struct FileBlobWriter: CacheBlobWriting {
    func append(_ bytes: some Collection<UInt8>, to url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes))
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
