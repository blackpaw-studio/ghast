import Foundation

/// One entry of New Runner's "Add to" menu.
struct NewRunnerScopeChoice: Identifiable, Hashable, Sendable {
    let scope: RunnerScope
    let avatarURL: String

    var id: RunnerScope { scope }
    var name: String { scope.displayName }
    var kind: String { scope.isOrganization ? "Organization" : "Repository" }
}

/// The "Add to" menu: organizations the user administers, then repositories they admin.
struct NewRunnerScopeChoices: Equatable, Sendable {
    let organizations: [NewRunnerScopeChoice]
    let repositories: [NewRunnerScopeChoice]

    init(organizations: [GitHubOrganization], repositories: [GitHubRepository]) {
        self.organizations = organizations
            .map { NewRunnerScopeChoice(scope: .organization(login: $0.login), avatarURL: $0.avatarURL) }
            .sorted(using: KeyPathComparator(\.name, comparator: .localizedStandard))
        self.repositories = repositories
            .filter(\.isAdmin)
            .map { NewRunnerScopeChoice(scope: $0.runnerScope, avatarURL: $0.owner.avatarURL) }
            .sorted(using: KeyPathComparator(\.name, comparator: .localizedStandard))
    }

    var all: [NewRunnerScopeChoice] { organizations + repositories }
    var first: NewRunnerScopeChoice? { all.first }

    func choice(for scope: RunnerScope?) -> NewRunnerScopeChoice? {
        all.first { $0.scope == scope }
    }
}
