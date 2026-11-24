import CryptoKit
import Foundation

/// Something that turns a bearer token into a grant (the real one is `CacheTokenVerifier`).
protocol CacheTokenVerifying: Sendable {
    func verify(bearer: String) async -> Result<CacheGrant, CacheAuthError>
}

extension CacheTokenVerifier: CacheTokenVerifying {}

/// The three `CacheService` Twirp methods `actions/cache` v4 calls. Every reply is JSON: a
/// message on 200, or a Twirp error body. Expected outcomes (a miss, a duplicate save, a
/// read-only token, a size mismatch) are `ok: false`, never an error status.
struct CacheTwirpService: Sendable {
    let store: CacheStore
    let verifier: any CacheTokenVerifying

    /// Handles `method` (the part after the service prefix). `serverBase` is the scheme, host
    /// and port the VM reached; signed URLs point at its root.
    func handle(method: String, bearer: String?, body: Data, serverBase: URL) async -> (TwirpResponse, CacheEvent?) {
        guard let route = Method(rawValue: method) else {
            return (Self.error(404, "bad_route", "no such method"), nil)
        }
        guard body.count <= CacheTwirp.maximumBodyBytes else {
            return (Self.error(400, "malformed", "request too large"), nil)
        }
        guard let bearer, case .success(let grant) = await verifier.verify(bearer: bearer) else {
            return (Self.error(401, "unauthenticated", "invalid token"), nil)
        }
        let links = SignedLinks(base: serverBase)
        do {
            switch route {
            case .create: return try await create(Self.decode(body), grant: grant, links: links)
            case .finalize: return try await finalize(Self.decode(body), grant: grant)
            case .get: return try await get(Self.decode(body), grant: grant, links: links)
            }
        } catch is RequestError {
            return (Self.error(400, "malformed", "invalid request"), nil)
        } catch {
            return (Self.error(500, "internal", "cache storage failed"), nil)
        }
    }

    private enum Method: String {
        case create = "CreateCacheEntry"
        case finalize = "FinalizeCacheEntryUpload"
        case get = "GetCacheEntryDownloadURL"
    }

    private struct RequestError: Error {}

    private func create(_ request: CacheTwirp.CreateRequest, grant: CacheGrant, links: SignedLinks)
        async throws -> (TwirpResponse, CacheEvent?) {
        try Self.validate(key: request.key, version: request.version)
        guard let scope = grant.writeScope else {
            return Self.createRefused(request.key, reason: "this job's token can't save to the cache")
        }
        guard let reservation = try await store.reserve(repo: grant.repo, scope: scope, key: request.key,
                                                        version: request.version) else {
            return Self.createRefused(request.key, reason: "an entry with this key already exists")
        }
        let url = links.upload(reservation)
        return (Self.ok(CacheTwirp.CreateResponse(ok: true, signed_upload_url: url, message: "")), nil)
    }

    private func finalize(_ request: CacheTwirp.FinalizeRequest, grant: CacheGrant) async throws -> (TwirpResponse, CacheEvent?) {
        try Self.validate(key: request.key, version: request.version)
        guard let scope = grant.writeScope else {
            return Self.finalizeRefused(request.key, reason: "this job's token can't save to the cache")
        }
        do {
            let entry = try await store.finalize(repo: grant.repo, scope: scope, key: request.key,
                                                 version: request.version, sizeBytes: request.size_bytes)
            let response = CacheTwirp.FinalizeResponse(ok: true, entry_id: Self.numericID(entry.id), message: "")
            return (Self.ok(response), .saved(key: request.key, sizeBytes: entry.sizeBytes))
        } catch let error as CacheStoreError {
            guard let reason = Self.refusalReason(error) else {
                return (Self.error(500, "internal", "cache storage failed"),
                        .saveSkipped(key: request.key, reason: "storage failed"))
            }
            return Self.finalizeRefused(request.key, reason: reason)
        }
    }

    private func get(_ request: CacheTwirp.GetRequest, grant: CacheGrant, links: SignedLinks) async throws -> (TwirpResponse, CacheEvent?) {
        let restoreKeys = request.restore_keys ?? []
        try Self.validate(key: request.key, version: request.version)
        guard restoreKeys.count <= CacheTwirp.maximumRestoreKeys,
              restoreKeys.allSatisfy({ $0.count <= CacheTwirp.maximumFieldLength }) else { throw RequestError() }
        guard let entry = await store.lookup(repo: grant.repo, readScopes: grant.readScopes, key: request.key,
                                             restoreKeys: restoreKeys, version: request.version) else {
            let response = CacheTwirp.GetResponse(ok: false, signed_download_url: "", matched_key: "")
            return (Self.ok(response), .miss(key: request.key))
        }
        let response = CacheTwirp.GetResponse(ok: true, signed_download_url: links.download(entry.downloadID),
                                              matched_key: entry.key)
        return (Self.ok(response), .hit(key: request.key, matchedKey: entry.key, sizeBytes: entry.sizeBytes))
    }

    /// The reason a finalize is refused with `ok: false`, or nil when it's a server fault.
    private static func refusalReason(_ error: CacheStoreError) -> String? {
        switch error {
        case .unknownUpload: "no upload is open for this key"
        case .commitInProgress: "the upload is still being committed"
        case .missingBlock: "a block of the upload is missing"
        case .nothingUploaded: "nothing was uploaded"
        case .sizeMismatch(let expected, let actual): "size mismatch (expected \(expected), got \(actual))"
        case .tooLarge(let size, let cap): "the archive (\(size) bytes) is larger than the cache (\(cap) bytes)"
        case .writeFailed, .indexWriteFailed: nil
        }
    }

    private static func createRefused(_ key: String, reason: String) -> (TwirpResponse, CacheEvent?) {
        (ok(CacheTwirp.CreateResponse(ok: false, signed_upload_url: "", message: reason)), .saveSkipped(key: key, reason: reason))
    }

    private static func finalizeRefused(_ key: String, reason: String) -> (TwirpResponse, CacheEvent?) {
        (ok(CacheTwirp.FinalizeResponse(ok: false, entry_id: "0", message: reason)), .saveSkipped(key: key, reason: reason))
    }

    private static func validate(key: String, version: String) throws {
        for field in [key, version] where field.isEmpty || field.count > CacheTwirp.maximumFieldLength {
            throw RequestError()
        }
    }

    private static func decode<T: Decodable>(_ body: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: body) } catch { throw RequestError() }
    }

    /// A stable int64 for `entry_id` (sent as a string): the first 6 bytes of SHA-256 of the
    /// entry's id, so it stays exact even where a client parses it as a double.
    static func numericID(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return String(digest.prefix(6).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func ok(_ message: some Encodable) -> TwirpResponse {
        TwirpResponse(status: 200, body: (try? encoder.encode(message)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> TwirpResponse {
        TwirpResponse(status: status, body: (try? encoder.encode(CacheTwirp.ErrorBody(code: code, msg: message))) ?? Data("{}".utf8))
    }
}

/// Upload and download URLs at the root of the address the VM used.
private struct SignedLinks {
    let base: URL

    func upload(_ reservation: CacheReservation) -> String {
        url(path: "/devstoreaccount1/upload/\(reservation.uploadID)", query: [URLQueryItem(name: "sig", value: reservation.signature)])
    }

    func download(_ downloadID: String) -> String {
        url(path: "/download/\(downloadID)", query: nil)
    }

    private func url(path: String, query: [URLQueryItem]?) -> String {
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        components.path = path
        components.queryItems = query
        return components.string ?? ""
    }
}
