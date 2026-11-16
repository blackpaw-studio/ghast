#if DEBUG
import Foundation

/// The design kit's world, as GitHub would report it. No network, no token.
enum FixtureWorld {
    static let user = GitHubUser(id: 1, login: "evancoleman", avatarURL: "", name: "Evan Coleman", email: nil)
    static let organization = GitHubOrganization(login: "blackpaw-studio", id: 10, avatarURL: "")
    static let repository = GitHubRepository(
        id: 20,
        name: "ghast",
        fullName: "blackpaw-studio/ghast",
        description: nil,
        isPrivate: false,
        owner: GitHubUser(id: 10, login: "blackpaw-studio", avatarURL: "", name: nil, email: nil),
        htmlURL: "https://github.com/blackpaw-studio/ghast"
    )
    static let organizationScope = RunnerScope.organization(login: organization.login)
    static let repositoryScope = RunnerScope.repository(fullName: repository.fullName)

    private static func labels(_ names: [String]) -> [GitHubRunnerLabel] {
        names.enumerated().map { index, name in
            GitHubRunnerLabel(id: index + 1, name: name, type: index < 3 ? "read-only" : "custom")
        }
    }

    /// What GitHub lists for the organization: this Mac's two org runners plus the two
    /// on other machines.
    static let organizationRunners: [GitHubRunner] = [
        GitHubRunner(id: 1001, name: "dionysus-arm64", os: "macOS", status: "online", busy: false, labels: labels(["self-hosted", "macOS", "ARM64"])),
        GitHubRunner(id: 1002, name: "dionysus-xcode", os: "macOS", status: "online", busy: true, labels: labels(["self-hosted", "macOS", "ARM64", "xcode"])),
        GitHubRunner(id: 1003, name: "helios-linux", os: "Linux", status: "online", busy: false, labels: labels(["self-hosted", "Linux", "X64"])),
        GitHubRunner(id: 1004, name: "iris-gpu", os: "Linux", status: "offline", busy: false, labels: labels(["self-hosted", "Linux", "X64", "gpu"])),
    ]

    static let repositoryRunners: [GitHubRunner] = [
        GitHubRunner(id: 2001, name: "ghast-release", os: "macOS", status: "offline", busy: false, labels: labels(["self-hosted", "macOS", "ARM64"])),
    ]
}

/// A `GitHubAPIServiceProtocol` that answers from `FixtureWorld` and never leaves the process.
@MainActor
final class FixtureGitHubAPIService: GitHubAPIServiceProtocol {
    /// False on the first-run screen, where this Mac has no runners yet, so GitHub lists only
    /// the other machines'.
    private let listsThisMacRunners: Bool

    init(listsThisMacRunners: Bool = true) {
        self.listsThisMacRunners = listsThisMacRunners
    }

    func setAccessToken(_ token: String) {}

    func fetchCurrentUser(token: String?) async throws -> AuthenticatedUser {
        AuthenticatedUser(user: FixtureWorld.user, grantedScopes: Set(GitHubAuthService.scopes))
    }

    func fetchRepositories() async throws -> [GitHubRepository] { [FixtureWorld.repository] }

    func fetchAdminOrganizations() async throws -> [GitHubOrganization] { [FixtureWorld.organization] }

    func fetchRunners(in scope: RunnerScope) async throws -> [GitHubRunner] {
        switch scope {
        case FixtureWorld.organizationScope:
            guard !listsThisMacRunners else { return FixtureWorld.organizationRunners }
            let localNames = Set(FixtureWorld.localRunners.map(\.name))
            return FixtureWorld.organizationRunners.filter { !localNames.contains($0.name) }
        case FixtureWorld.repositoryScope:
            return listsThisMacRunners ? FixtureWorld.repositoryRunners : []
        default: return []
        }
    }

    func createRegistrationToken(for scope: RunnerScope) async throws -> GitHubRunnerRegistrationToken {
        GitHubRunnerRegistrationToken(token: "fixture-registration-token", expiresAt: "2026-11-16T11:12:00Z")
    }

    func createRemoveToken(for scope: RunnerScope) async throws -> GitHubRunnerRemoveToken {
        GitHubRunnerRemoveToken(token: "fixture-remove-token", expiresAt: "2026-11-16T11:12:00Z")
    }

    func deleteRunner(runnerId: Int, from scope: RunnerScope) async throws {}

    func fetchRunnerApplications(for scope: RunnerScope) async throws -> [GitHubRunnerApplication] {
        [GitHubRunnerApplication(
            os: "osx",
            architecture: "arm64",
            downloadURL: "https://fixture.invalid/actions-runner-osx-arm64-2.329.0.tar.gz",
            filename: "actions-runner-osx-arm64-2.329.0.tar.gz"
        )]
    }
}
#endif
