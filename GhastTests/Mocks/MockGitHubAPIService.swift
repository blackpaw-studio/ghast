import Foundation
@testable import Ghast

/// Mock GitHub API Service that returns fake data without making network calls
@MainActor
class MockGitHubAPIService: GitHubAPIServiceProtocol {
    
    private(set) var accessTokens: [String] = []
    var shouldThrowError = false
    var mockRepositories: [GitHubRepository] = []
    var mockRunners: [GitHubRunner] = []
    
    /// When true, `fetchRepositories` suspends until `releasePendingRequests()`, so a test can
    /// capture the in-flight (loading) state deterministically.
    var holdsRepositoriesPending = false
    private var pendingRepositoryRequests: [CheckedContinuation<Void, Error>] = []
    
    /// Resumes every held request; call before the mock goes away so no continuation is dropped.
    func releasePendingRequests() {
        let pending = pendingRepositoryRequests
        pendingRepositoryRequests = []
        pending.forEach { $0.resume() }
    }
    
    func setAccessToken(_ token: String) {
        accessTokens.append(token)
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
        if holdsRepositoriesPending {
            try await withCheckedThrowingContinuation { pendingRepositoryRequests.append($0) }
        }
        if shouldThrowError {
            throw GitHubAPIError.networkError(URLError(.notConnectedToInternet))
        }
        
        // Return mock repositories if set, otherwise empty
        return mockRepositories
    }
    
    func fetchRunners(in scope: RunnerScope) async throws -> [GitHubRunner] {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        // Return mock runners if set, otherwise empty
        return mockRunners
    }
    
    func createRegistrationToken(for scope: RunnerScope) async throws -> GitHubRunnerRegistrationToken {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        return GitHubRunnerRegistrationToken(
            token: "mock-registration-token",
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        )
    }
    
    func createRemoveToken(for scope: RunnerScope) async throws -> GitHubRunnerRemoveToken {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        return GitHubRunnerRemoveToken(
            token: "mock-remove-token",
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        )
    }
    
    func deleteRunner(runnerId: Int, from scope: RunnerScope) async throws {
        if shouldThrowError {
            throw GitHubAPIError.notFound
        }
        // Successfully "deleted"
    }
    
    func fetchRunnerApplications(for scope: RunnerScope) async throws -> [GitHubRunnerApplication] {
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