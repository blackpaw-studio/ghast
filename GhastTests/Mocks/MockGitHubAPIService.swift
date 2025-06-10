import Foundation
@testable import Ghast

/// Mock GitHub API Service that returns fake data without making network calls
class MockGitHubAPIService: GitHubAPIServiceProtocol {
    
    var shouldThrowError = false
    var mockRepositories: [GitHubRepository] = []
    var mockRunners: [GitHubRunner] = []
    
    func setAccessToken(_ token: String) {
        // Do nothing
    }
    
    func fetchCurrentUser(token: String? = nil) async throws -> GitHubUser {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        return GitHubUser(
            id: 12345,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
    }
    
    func fetchRepositories() async throws -> [GitHubRepository] {
        if shouldThrowError {
            throw GitHubAPIError.networkError(URLError(.notConnectedToInternet))
        }
        
        // Return mock repositories if set, otherwise empty
        return mockRepositories
    }
    
    func fetchRunners(for repository: GitHubRepository) async throws -> [GitHubRunner] {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        // Return mock runners if set, otherwise empty
        return mockRunners
    }
    
    func createRegistrationToken(for repository: GitHubRepository) async throws -> GitHubRunnerRegistrationToken {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        return GitHubRunnerRegistrationToken(
            token: "mock-registration-token",
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        )
    }
    
    func fetchOrganizationRunners(org: String) async throws -> [GitHubRunner] {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        return mockRunners
    }
    
    func createRemoveToken(for repository: GitHubRepository) async throws -> GitHubRunnerRemoveToken {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        return GitHubRunnerRemoveToken(
            token: "mock-remove-token",
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        )
    }
    
    func deleteRunner(runnerId: Int, from repository: GitHubRepository) async throws {
        if shouldThrowError {
            throw GitHubAPIError.notFound
        }
        // Successfully "deleted"
    }
    
    func fetchRunnerApplications(for repository: GitHubRepository) async throws -> [GitHubRunnerApplication] {
        if shouldThrowError {
            throw GitHubAPIError.networkError(URLError(.notConnectedToInternet))
        }
        
        return [
            GitHubRunnerApplication(
                os: "osx",
                architecture: "arm64",
                downloadURL: "https://example.com/runner-arm64.tar.gz",
                filename: "runner-arm64.tar.gz"
            ),
            GitHubRunnerApplication(
                os: "osx",
                architecture: "x64",
                downloadURL: "https://example.com/runner-x64.tar.gz",
                filename: "runner-x64.tar.gz"
            )
        ]
    }
}