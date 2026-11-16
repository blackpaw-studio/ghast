import Foundation
import Testing
@testable import Ghast

@Suite("New Runner scope choices")
struct NewRunnerScopeChoicesTests {
    private static let owner = GitHubUser(id: 1, login: "me", avatarURL: "", name: nil, email: nil)

    private static func repo(_ fullName: String, admin: Bool?) -> GitHubRepository {
        GitHubRepository(
            id: fullName.hashValue, name: fullName, fullName: fullName, description: nil, isPrivate: false,
            owner: owner, htmlURL: "", permissions: admin.map { RepositoryPermissions(admin: $0) }
        )
    }

    @Test func listsOrganizationsThenOnlyAdminRepositoriesSortedByName() {
        let choices = NewRunnerScopeChoices(
            organizations: [GitHubOrganization(login: "zeta", id: 2, avatarURL: ""), GitHubOrganization(login: "acme", id: 1, avatarURL: "a")],
            repositories: [Self.repo("me/b", admin: true), Self.repo("me/a", admin: true), Self.repo("me/read-only", admin: false), Self.repo("me/unknown", admin: nil)]
        )
        #expect(choices.organizations.map(\.scope) == [.organization(login: "acme"), .organization(login: "zeta")])
        #expect(choices.repositories.map(\.scope) == [.repository(fullName: "me/a"), .repository(fullName: "me/b")])
        #expect(choices.first?.scope == .organization(login: "acme"))
    }

    @Test func decodesRepositoryAdminPermission() throws {
        let json = #"{"id":1,"name":"a","full_name":"me/a","description":null,"private":false,"html_url":"","owner":{"id":1,"login":"me","avatar_url":""},"permissions":{"admin":true,"push":true,"pull":true}}"#
        let repo = try JSONDecoder().decode(GitHubRepository.self, from: Data(json.utf8))
        #expect(repo.isAdmin)
    }
}
