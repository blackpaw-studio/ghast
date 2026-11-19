import Foundation
@testable import Ghast

/// Mock GitHub API Service that returns fake data without making network calls
@MainActor
class MockGitHubAPIService: GitHubAPIServiceProtocol {
    
    private(set) var accessTokens: [String] = []
    var shouldThrowError = false
    var mockRepositories: [GitHubRepository] = []
    var mockRunners: [GitHubRunner] = []
    var mockOrganizations: [GitHubOrganization] = []
    /// Scopes whose runner calls fail, to exercise one-scope-fails paths.
    var failingScopes: Set<RunnerScope> = []
    /// A specific error per scope for `fetchRunners`.
    var runnerErrors: [RunnerScope: Error] = [:]
    /// Every scope `fetchRunners` was asked for, in order.
    private(set) var runnerFetches: [RunnerScope] = []
    
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
    
    func fetchCurrentUser(token: String? = nil) async throws -> AuthenticatedUser {
        if shouldThrowError {
            throw GitHubAPIError.unauthorized
        }
        
        return AuthenticatedUser(user: mockUser, grantedScopes: Set(GitHubAuthService.scopes))
    }

    private var mockUser: GitHubUser {
        GitHubUser(
            id: 12345,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
    }
    
    /// How many times `fetchRepositories` was called.
    private(set) var repositoryFetchCount = 0

    func fetchRepositories() async throws -> [GitHubRepository] {
        repositoryFetchCount += 1
        if holdsRepositoriesPending {
            try await withCheckedThrowingContinuation { pendingRepositoryRequests.append($0) }
        }
        if shouldThrowError {
            throw GitHubAPIError.networkError(URLError(.notConnectedToInternet))
        }
        
        // Return mock repositories if set, otherwise empty
        return mockRepositories
    }
    
    func fetchAdminOrganizations() async throws -> [GitHubOrganization] {
        if shouldThrowError {
            throw GitHubAPIError.networkError(URLError(.notConnectedToInternet))
        }
        return mockOrganizations
    }

    func fetchRunners(in scope: RunnerScope) async throws -> [GitHubRunner] {
        runnerFetches.append(scope)
        if let error = runnerErrors[scope] { throw error }
        if shouldThrowError || failingScopes.contains(scope) {
            throw GitHubAPIError.unauthorized
        }
        
        // Return mock runners if set, otherwise empty
        return mockRunners
    }
    
    /// Every scope `createRegistrationToken` was asked for, in order.
    private(set) var registrationTokenScopes: [RunnerScope] = []

    func createRegistrationToken(for scope: RunnerScope) async throws -> GitHubRunnerRegistrationToken {
        registrationTokenScopes.append(scope)
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
    
    var mockRunnerGroups: [GitHubRunnerGroup] = [GitHubRunnerGroup(id: 1, name: "Default", isDefault: true)]

    func fetchRunnerGroups(org: String) async throws -> [GitHubRunnerGroup] {
        if shouldThrowError { throw GitHubAPIError.unauthorized }
        return mockRunnerGroups
    }

    func generateJITConfig(
        for scope: RunnerScope,
        name: String,
        runnerGroupID: Int,
        labels: [String],
        workFolder: String
    ) async throws -> GitHubJITConfig {
        if shouldThrowError { throw GitHubAPIError.unauthorized }
        return GitHubJITConfig(runnerID: 1, encodedConfig: "mock-jit-config")
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