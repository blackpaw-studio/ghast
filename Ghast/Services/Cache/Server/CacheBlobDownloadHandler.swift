import Foundation

/// Serves `GET` and `HEAD /download/{id}` for restores. `x-ms-range` wins over `Range`; one
/// range is honoured and anything else (several ranges, a malformed or unsatisfiable one) is
/// 416. The file is opened here, so a blob evicted after this call still streams in full.
struct CacheBlobDownloadHandler: Sendable {
    let store: CacheStore

    func handle(method: String, downloadID: String, headers: [String: String]) async -> BlobDownloadResponse {
        guard method == "GET" || method == "HEAD" else { return .status(405) }
        guard let url = await store.blobURL(downloadID: downloadID),
              let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else { return .status(404) }
        let base = ["accept-ranges": "bytes", "content-type": "application/octet-stream", "x-ms-blob-type": "BlockBlob"]

        let status: Int, range: ClosedRange<UInt64>?
        switch headers["x-ms-range"] ?? headers["range"] {
        case nil:
            (status, range) = (200, size == 0 ? nil : 0 ... size - 1)
        case let header?:
            guard let satisfiable = Self.range(header, size: size) else {
                try? handle.close()
                return BlobDownloadResponse(status: 416, headers: base.merging(["content-range": "bytes */\(size)"]) { $1 },
                                            body: nil)
            }
            (status, range) = (206, satisfiable)
        }

        let length = range.map { $0.upperBound - $0.lowerBound + 1 } ?? 0
        var responseHeaders = base.merging(["content-length": String(length)]) { $1 }
        if status == 206, let range {
            responseHeaders["content-range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        }
        guard method == "GET" else {
            try? handle.close()
            return BlobDownloadResponse(status: status, headers: responseHeaders, body: nil)
        }
        let body = BlobFileBody(reader: BlobFileReader(handle: handle, offset: range?.lowerBound ?? 0, length: length))
        return BlobDownloadResponse(status: status, headers: responseHeaders, body: body)
    }

    /// The one satisfiable range in `header` (`bytes=a-b`, `bytes=a-` or `bytes=-n`), else nil.
    static func range(_ header: String, size: UInt64) -> ClosedRange<UInt64>? {
        let prefix = "bytes="
        guard header.hasPrefix(prefix), size > 0 else { return nil }
        let spec = header.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash], endText = spec[spec.index(after: dash)...]
        if startText.isEmpty {
            guard let suffix = UInt64(endText), suffix > 0 else { return nil }
            return (size - min(suffix, size)) ... size - 1
        }
        guard let start = UInt64(startText), start < size else { return nil }
        guard !endText.isEmpty else { return start ... size - 1 }
        guard let end = UInt64(endText), end >= start else { return nil }
        return start ... min(end, size - 1)
    }
}

struct BlobDownloadResponse: Sendable {
    let status: Int
    let headers: [String: String]
    /// The bytes to send; nil for HEAD and errors.
    let body: BlobFileBody?

    static func status(_ status: Int) -> BlobDownloadResponse {
        BlobDownloadResponse(status: status, headers: ["content-length": "0"], body: nil)
    }
}

/// A slice of an open blob file, read in chunks as the response is sent.
struct BlobFileBody: Sendable {
    fileprivate let reader: BlobFileReader

    var length: UInt64 { reader.length }

    func chunks(size: Int = 1 << 20) -> AsyncThrowingStream<Data, Error> {
        let reader = reader
        return AsyncThrowingStream { try reader.next(maximum: size) }
    }
}

/// Owns the file handle; reads are serial (one stream per response) and it closes on deinit.
private final class BlobFileReader: @unchecked Sendable {
    let length: UInt64
    private let handle: FileHandle
    private let lock = NSLock()
    private var position: UInt64
    private var remaining: UInt64

    init(handle: FileHandle, offset: UInt64, length: UInt64) {
        self.handle = handle
        self.length = length
        position = offset
        remaining = length
    }

    deinit { try? handle.close() }

    func next(maximum: Int) throws -> Data? {
        try lock.withLock {
            guard remaining > 0 else { return nil }
            try handle.seek(toOffset: position)
            let count = Int(min(UInt64(maximum), remaining))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            position += UInt64(data.count)
            remaining -= UInt64(data.count)
            return data
        }
    }
}
