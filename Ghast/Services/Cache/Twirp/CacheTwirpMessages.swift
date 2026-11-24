import Foundation

/// Twirp JSON messages of `github.actions.results.api.v1.CacheService` (snake_case). int64
/// fields travel as JSON strings; `size_bytes` is also accepted as a number.
enum CacheTwirp {
    static let servicePrefix = "github.actions.results.api.v1.CacheService/"
    /// Largest Twirp request body accepted.
    static let maximumBodyBytes = 64 * 1024
    /// Longest key, restore key or version accepted (GitHub limits keys to 512 characters).
    static let maximumFieldLength = 512
    static let maximumRestoreKeys = 10

    struct CreateRequest: Decodable {
        let key: String
        let version: String
    }

    struct CreateResponse: Encodable, Equatable {
        let ok: Bool
        let signed_upload_url: String
        let message: String
    }

    struct FinalizeRequest: Decodable {
        let key: String
        let version: String
        let size_bytes: Int64

        enum CodingKeys: String, CodingKey { case key, version, size_bytes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            version = try container.decode(String.self, forKey: .version)
            if let text = try? container.decode(String.self, forKey: .size_bytes) {
                guard let value = Int64(text) else {
                    throw DecodingError.dataCorruptedError(forKey: .size_bytes, in: container, debugDescription: "not an int64")
                }
                size_bytes = value
            } else {
                size_bytes = try container.decode(Int64.self, forKey: .size_bytes)
            }
        }
    }

    struct FinalizeResponse: Encodable, Equatable {
        let ok: Bool
        let entry_id: String
        let message: String
    }

    struct GetRequest: Decodable {
        let key: String
        let restore_keys: [String]?
        let version: String
    }

    struct GetResponse: Encodable, Equatable {
        let ok: Bool
        let signed_download_url: String
        let matched_key: String
    }

    /// A Twirp error body.
    struct ErrorBody: Encodable, Equatable {
        let code: String
        let msg: String
    }
}

/// What one cache call did, for the runner log. Never carries a token.
enum CacheEvent: Equatable, Sendable {
    case hit(key: String, matchedKey: String, sizeBytes: Int64)
    case miss(key: String)
    case saved(key: String, sizeBytes: Int64)
    case saveSkipped(key: String, reason: String)
}

/// A Twirp reply: a status and a JSON body, never HTML.
struct TwirpResponse: Equatable, Sendable {
    let status: Int
    let body: Data
}
