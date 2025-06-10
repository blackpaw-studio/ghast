import Foundation
import SwiftUI

/// Protocol for GitHub API operations to enable testing
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

/// Environment key for injecting API service
struct GitHubAPIServiceKey: EnvironmentKey {
    static let defaultValue: GitHubAPIServiceProtocol = GitHubAPIService.shared
}

extension EnvironmentValues {
    var gitHubAPIService: GitHubAPIServiceProtocol {
        get { self[GitHubAPIServiceKey.self] }
        set { self[GitHubAPIServiceKey.self] = newValue }
    }
}