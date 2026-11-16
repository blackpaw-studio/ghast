import Foundation

struct GitHubUser: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let login: String
    let avatarURL: String
    let name: String?
    let email: String?
    
    enum CodingKeys: String, CodingKey {
        case id, login, name, email
        case avatarURL = "avatar_url"
    }
}

/// The signed-in user plus the OAuth scopes GitHub reports for the token.
struct AuthenticatedUser: Equatable, Sendable {
    let user: GitHubUser
    /// From the `X-OAuth-Scopes` response header; nil when the header is absent.
    let grantedScopes: Set<String>?

    /// Parses a comma-separated `X-OAuth-Scopes` value (`"repo, user:email"`).
    static func scopes(fromHeader header: String?) -> Set<String>? {
        header.map { value in
            Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }
}

struct GitHubRepository: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let isPrivate: Bool
    let owner: GitHubUser
    let htmlURL: String
    /// The signed-in user's access; GitHub includes it on authenticated repository lists.
    var permissions: RepositoryPermissions? = nil

    /// Runners can be added only where the user is an admin.
    var isAdmin: Bool { permissions?.admin == true }

    enum CodingKeys: String, CodingKey {
        case id, name, description, owner, permissions
        case fullName = "full_name"
        case isPrivate = "private"
        case htmlURL = "html_url"
    }
}

struct RepositoryPermissions: Codable, Equatable, Sendable {
    let admin: Bool
}

/// An organization the signed-in user administers.
struct GitHubOrganization: Codable, Identifiable, Hashable, Sendable {
    let login: String
    let id: Int
    let avatarURL: String

    enum CodingKeys: String, CodingKey {
        case login, id
        case avatarURL = "avatar_url"
    }
}

struct GitHubRunner: Sendable, Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let os: String
    let status: String
    let busy: Bool
    let labels: [GitHubRunnerLabel]
    
    var isOnline: Bool {
        status == "online"
    }
    
    var statusColor: String {
        switch status {
        case "online":
            return busy ? "orange" : "green"
        case "offline":
            return "red"
        default:
            return "gray"
        }
    }
}

struct GitHubRunnerLabel: Sendable, Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let type: String
}

struct GitHubRunnerRegistrationToken: Sendable, Codable {
    let token: String
    let expiresAt: String
    
    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

struct GitHubRunnerRemoveToken: Sendable, Codable {
    let token: String
    let expiresAt: String
    
    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

struct GitHubRunnerApplication: Sendable, Codable {
    let os: String
    let architecture: String
    let downloadURL: String
    let filename: String
    
    enum CodingKeys: String, CodingKey {
        case os, architecture, filename
        case downloadURL = "download_url"
    }
}

enum GitHubAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case noAccessToken
    case invalidResponse
    case unauthorized
    case notFound
    case serverError(Int)
    case httpStatus(Int)
    case networkError(Error)
    case decodingError(Error)
    /// The API service was never injected (see `UnconfiguredGitHubAPIService`).
    case notConfigured
    /// GitHub's primary or secondary rate limit (403 or 429). `retryAfter` comes from
    /// `Retry-After`; `resetAt` from `X-RateLimit-Reset` when `X-RateLimit-Remaining` is 0.
    case rateLimited(status: Int, retryAfter: TimeInterval?, resetAt: Date?)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noAccessToken:
            return "No access token available"
        case .invalidResponse:
            return "Invalid response from GitHub API"
        case .unauthorized:
            return "Unauthorized. Please check your GitHub token permissions."
        case .notFound:
            return "Resource not found"
        case .serverError(let code):
            return "Server error: \(code)"
        case .httpStatus(let code):
            return "GitHub returned HTTP \(code)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .notConfigured:
            return "GitHub API service is not configured"
        case .rateLimited:
            return "GitHub's rate limit was reached. Ghast will try again later."
        }
    }

    /// When a rate-limited request may be retried; nil for any other error. Without either
    /// header GitHub asks clients to wait at least a minute.
    func retryDate(now: Date) -> Date? {
        guard case let .rateLimited(_, retryAfter, resetAt) = self else { return nil }
        return retryAfter.map { now.addingTimeInterval($0) } ?? resetAt ?? now.addingTimeInterval(Self.defaultRateLimitWait)
    }

    static let defaultRateLimitWait: TimeInterval = 60

    /// HTTP status behind this error, when it came from a response.
    var statusCode: Int? {
        switch self {
        case .unauthorized: 401
        case .notFound: 404
        case .serverError(let code), .httpStatus(let code), .rateLimited(let code, _, _): code
        default: nil
        }
    }
}
/// An organization's runner group (`GET /orgs/{org}/actions/runner-groups`).
struct GitHubRunnerGroup: Sendable, Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "default"
    }
}
