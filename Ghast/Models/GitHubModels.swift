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
    
    enum CodingKeys: String, CodingKey {
        case id, name, description, owner
        case fullName = "full_name"
        case isPrivate = "private"
        case htmlURL = "html_url"
    }
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
        }
    }

    /// HTTP status behind this error, when it came from a response.
    var statusCode: Int? {
        switch self {
        case .unauthorized: 401
        case .notFound: 404
        case .serverError(let code), .httpStatus(let code): code
        default: nil
        }
    }
}