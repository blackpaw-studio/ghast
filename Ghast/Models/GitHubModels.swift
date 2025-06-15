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
    case forbidden(String?) // With optional message about missing permissions
    case notFound
    case rateLimitExceeded(resetDate: Date?)
    case validationError([String: String]) // Field-specific errors
    case serverError(Int)
    case networkError(Error)
    case decodingError(Error)
    case timeout
    case offline
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noAccessToken:
            return "No access token available"
        case .invalidResponse:
            return "Invalid response from GitHub API"
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .forbidden(let message):
            if let message = message {
                return "Access denied: \(message)"
            }
            return "You don't have permission to perform this action."
        case .notFound:
            return "The requested resource was not found."
        case .rateLimitExceeded(let resetDate):
            if let reset = resetDate {
                let formatter = RelativeDateTimeFormatter()
                return "API rate limit exceeded. Try again \(formatter.localizedString(for: reset, relativeTo: Date()))."
            }
            return "API rate limit exceeded. Please try again later."
        case .validationError(let errors):
            let errorMessages = errors.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return "Validation error: \(errorMessages)"
        case .serverError(let code):
            return "GitHub server error (\(code)). Please try again later."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to process server response: \(error.localizedDescription)"
        case .timeout:
            return "Request timed out. Please check your connection and try again."
        case .offline:
            return "No internet connection. Please check your network settings."
        }
    }
    
    var isRetryable: Bool {
        switch self {
        case .rateLimitExceeded, .serverError, .networkError, .timeout:
            return true
        default:
            return false
        }
    }
    
    var requiresReauthentication: Bool {
        switch self {
        case .unauthorized:
            return true
        default:
            return false
        }
    }
}