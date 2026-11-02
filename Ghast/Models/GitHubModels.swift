import Foundation

struct GitHubUser: Codable, Identifiable, Equatable {
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

struct GitHubRepository: Codable, Identifiable, Equatable {
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

struct GitHubRunner: Codable, Identifiable {
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

struct GitHubRunnerLabel: Codable, Identifiable {
    let id: Int
    let name: String
    let type: String
}

struct GitHubRunnerRegistrationToken: Codable {
    let token: String
    let expiresAt: String
    
    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

struct GitHubRunnerRemoveToken: Codable {
    let token: String
    let expiresAt: String
    
    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

struct GitHubRunnerApplication: Codable {
    let os: String
    let architecture: String
    let downloadURL: String
    let filename: String
    
    enum CodingKeys: String, CodingKey {
        case os, architecture, filename
        case downloadURL = "download_url"
    }
}

enum GitHubAPIError: Error, LocalizedError {
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