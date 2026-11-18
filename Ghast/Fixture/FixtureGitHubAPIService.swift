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
        htmlURL: "https://github.com/blackpaw-studio/ghast",
        permissions: RepositoryPermissions(admin: true)
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

    /// New Runner's "Setting Up" screen, frozen at "Start runner".
    static let setupProgress = SetupProgress(
        runnerName: "dionysus-3",
        scopeName: organization.login,
        version: "2.329.0",
        states: [
            .download: .done(detail: "182 MB"),
            .register: .done(detail: nil),
            .start: .active(detail: SetupProgress.connectingDetail),
        ]
    )

    static let repositoryRunners: [GitHubRunner] = [
        GitHubRunner(id: 2001, name: "ghast-release", os: "macOS", status: "offline", busy: false, labels: labels(["self-hosted", "macOS", "ARM64"])),
    ]
}

/// How the fixture's repository list arrives.
enum FixtureRepositoryLoad: Equatable, Sendable {
    case immediate
    /// Arrives after the given delay, as a slow `/user/repos` would.
    case delayed(Duration)
    /// Never arrives: the sheet stays in its loading state.
    case pending
    /// GitHub can't be reached.
    case failing
}

/// Which account the fixture's GitHub answers for.
enum FixtureAccount: Equatable, Sendable {
    /// The design kit's one organization and repository.
    case kit
    /// Many organizations and repositories, some with long names (New Runner's busy states).
    case busy(repositories: FixtureRepositoryLoad)
}

extension FixtureWorld {
    private static func owner(_ login: String, id: Int) -> GitHubUser {
        GitHubUser(id: id, login: login, avatarURL: "", name: nil, email: nil)
    }

    private static let busyOrganizationLogins = [
        "blackpaw-studio", "evandcoleman-labs", "olympus-homelab",
        "an-extraordinarily-long-organization-name-collective",
    ]

    static let busyOrganizations: [GitHubOrganization] = busyOrganizationLogins.enumerated().map { index, login in
        GitHubOrganization(login: login, id: 100 + index, avatarURL: "")
    }

    /// Thirty admin repositories across the organizations, a few with very long names, plus
    /// some the user can't administer (left out of the menu).
    static let busyRepositories: [GitHubRepository] = {
        let names: [(owner: String, name: String, admin: Bool)] = [
            ("blackpaw-studio", "ghast", true),
            ("blackpaw-studio", "ghast-github-actions-self-hosted-runner-manager-for-macos-tahoe", true),
            ("blackpaw-studio", "leo", true),
            ("blackpaw-studio", "marketing-site", false),
            ("evandcoleman", "dotfiles", true),
            ("evandcoleman", "an-unreasonably-long-repository-name-that-keeps-going-and-going", true),
            ("an-extraordinarily-long-organization-name-collective", "infrastructure-as-code-monorepo", true),
            ("olympus-homelab", "nomad-jobs", true),
            ("olympus-homelab", "consul-templates", false),
        ] + (1...22).map { ("evandcoleman-labs", "experiment-\($0)", true) }
        return names.enumerated().map { index, entry in
            GitHubRepository(
                id: 300 + index,
                name: entry.name,
                fullName: "\(entry.owner)/\(entry.name)",
                description: nil,
                isPrivate: false,
                owner: owner(entry.owner, id: 400 + index),
                htmlURL: "https://github.com/\(entry.owner)/\(entry.name)",
                permissions: RepositoryPermissions(admin: entry.admin)
            )
        }
    }()
}

/// A `GitHubAPIServiceProtocol` that answers from `FixtureWorld` and never leaves the process.
@MainActor
final class FixtureGitHubAPIService: GitHubAPIServiceProtocol {
    /// False on the first-run screen, where this Mac has no runners yet, so GitHub lists only
    /// the other machines'.
    private let listsThisMacRunners: Bool
    private let account: FixtureAccount

    init(listsThisMacRunners: Bool = true, account: FixtureAccount = .kit) {
        self.listsThisMacRunners = listsThisMacRunners
        self.account = account
    }

    func setAccessToken(_ token: String) {}

    func fetchCurrentUser(token: String?) async throws -> AuthenticatedUser {
        AuthenticatedUser(user: FixtureWorld.user, grantedScopes: Set(GitHubAuthService.scopes))
    }

    func fetchRepositories() async throws -> [GitHubRepository] {
        guard case let .busy(load) = account else { return [FixtureWorld.repository] }
        switch load {
        case .immediate: break
        case let .delayed(delay): try await Task.sleep(for: delay)
        case .pending: try await Task.sleep(for: .seconds(3_600))
        case .failing: throw GitHubAPIError.networkError(URLError(.notConnectedToInternet))
        }
        return FixtureWorld.busyRepositories
    }

    func fetchAdminOrganizations() async throws -> [GitHubOrganization] {
        account == .kit ? [FixtureWorld.organization] : FixtureWorld.busyOrganizations
    }

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

    func fetchRunnerGroups(org: String) async throws -> [GitHubRunnerGroup] {
        [GitHubRunnerGroup(id: 1, name: "Default", isDefault: true)]
    }

    func generateJITConfig(
        for scope: RunnerScope,
        name: String,
        runnerGroupID: Int,
        labels: [String],
        workFolder: String
    ) async throws -> GitHubJITConfig {
        GitHubJITConfig(runnerID: 9_001, encodedConfig: "fixture-jit-config")
    }

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
