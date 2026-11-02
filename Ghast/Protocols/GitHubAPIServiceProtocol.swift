import Foundation
import SwiftUI
import os

/// Protocol for GitHub API operations to enable testing
@MainActor
protocol GitHubAPIServiceProtocol {
    func setAccessToken(_ token: String)
    func fetchCurrentUser(token: String?) async throws -> GitHubUser
    func fetchRepositories() async throws -> [GitHubRepository]
    func fetchRunners(for repository: GitHubRepository) async throws -> [GitHubRunner]
    func fetchOrganizationRunners(org: String) async throws -> [GitHubRunner]
    func createRegistrationToken(for repository: GitHubRepository) async throws -> GitHubRunnerRegistrationToken
    func createRemoveToken(for repository: GitHubRepository) async throws -> GitHubRunnerRemoveToken
    func deleteRunner(runnerId: Int, from repository: GitHubRepository) async throws
    func fetchRunnerApplications(for repository: GitHubRepository) async throws -> [GitHubRunnerApplication]
}

/// Inert default for the environment key: never touches the network or a token.
/// Every call throws `GitHubAPIError.notConfigured` and logs a fault, so a view that
/// was never given a real service shows an error state instead of crashing.
struct UnconfiguredGitHubAPIService: GitHubAPIServiceProtocol {
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "api")

    nonisolated init() {}

    private func unconfigured(_ operation: String) -> GitHubAPIError {
        Self.logger.fault("GitHubAPIService not injected; \(operation, privacy: .public) called on the unconfigured default")
        return .notConfigured
    }

    func setAccessToken(_ token: String) {
        Self.logger.fault("GitHubAPIService not injected; setAccessToken called on the unconfigured default")
    }
    func fetchCurrentUser(token: String?) async throws -> GitHubUser { throw unconfigured("fetchCurrentUser") }
    func fetchRepositories() async throws -> [GitHubRepository] { throw unconfigured("fetchRepositories") }
    func fetchRunners(for repository: GitHubRepository) async throws -> [GitHubRunner] { throw unconfigured("fetchRunners") }
    func fetchOrganizationRunners(org: String) async throws -> [GitHubRunner] { throw unconfigured("fetchOrganizationRunners") }
    func createRegistrationToken(for repository: GitHubRepository) async throws -> GitHubRunnerRegistrationToken { throw unconfigured("createRegistrationToken") }
    func createRemoveToken(for repository: GitHubRepository) async throws -> GitHubRunnerRemoveToken { throw unconfigured("createRemoveToken") }
    func deleteRunner(runnerId: Int, from repository: GitHubRepository) async throws { throw unconfigured("deleteRunner") }
    func fetchRunnerApplications(for repository: GitHubRepository) async throws -> [GitHubRunnerApplication] { throw unconfigured("fetchRunnerApplications") }
}

/// Environment key for injecting API service
struct GitHubAPIServiceKey: EnvironmentKey {
    // Computed so each read builds a fresh instance; avoids a non-Sendable `static let`.
    static var defaultValue: any GitHubAPIServiceProtocol { UnconfiguredGitHubAPIService() }
}

extension EnvironmentValues {
    var gitHubAPIService: any GitHubAPIServiceProtocol {
        get { self[GitHubAPIServiceKey.self] }
        set { self[GitHubAPIServiceKey.self] = newValue }
    }
}