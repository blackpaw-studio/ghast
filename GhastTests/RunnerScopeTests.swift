import Testing
import Foundation
@testable import Ghast

@Suite struct RunnerScopeTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let scope: RunnerScope
        let apiPathPrefix: String
        let configURL: String
        let displayName: String
        let isOrganization: Bool
        var testDescription: String { displayName }
    }

    static let cases = [
        Case(scope: .repository(fullName: "octo/ghast"), apiPathPrefix: "/repos/octo/ghast",
             configURL: "https://github.com/octo/ghast", displayName: "octo/ghast", isOrganization: false),
        Case(scope: .organization(login: "acme"), apiPathPrefix: "/orgs/acme",
             configURL: "https://github.com/acme", displayName: "acme", isOrganization: true),
    ]

    @Test(arguments: cases)
    func derivedValues(_ c: Case) {
        #expect(c.scope.apiPathPrefix == c.apiPathPrefix)
        #expect(c.scope.configURL == c.configURL)
        #expect(c.scope.displayName == c.displayName)
        #expect(c.scope.isOrganization == c.isOrganization)
    }

    @Test(arguments: cases)
    func codableRoundTrip(_ c: Case) throws {
        let data = try JSONEncoder().encode(c.scope)
        #expect(try JSONDecoder().decode(RunnerScope.self, from: data) == c.scope)
    }

    @Test func encodesExplicitKindAndName() throws {
        let data = try JSONEncoder().encode(RunnerScope.organization(login: "acme"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["kind": "organization", "name": "acme"])
    }

    @Test(arguments: [
        ("https://github.com/acme", RunnerScope.organization(login: "acme")),
        ("https://github.com/acme/", .organization(login: "acme")),
        ("https://github.com/octo/ghast", .repository(fullName: "octo/ghast")),
        ("https://github.com/octo/ghast/", .repository(fullName: "octo/ghast")),
        // Extra components are ignored, as discovery did before scopes existed.
        ("https://github.com/octo/ghast/extra", .repository(fullName: "octo/ghast")),
    ])
    func parsesGitHubURL(url: String, expected: RunnerScope) {
        #expect(RunnerScope(gitHubURL: url) == expected)
    }

    @Test(arguments: [
        "https://example.com/acme",
        "https://github.com",
        "https://github.com/",
        "not a url",
    ])
    func rejectsUnrecognisedURL(url: String) {
        #expect(RunnerScope(gitHubURL: url) == nil)
    }

    @Test func repositoryRunnerScopeUsesFullName() throws {
        let json = """
        {"id":7,"name":"ghast","full_name":"octo/ghast","description":null,"private":false,\
        "owner":{"id":1,"login":"octo","avatar_url":"https://a/1","name":null,"email":null},\
        "html_url":"https://github.com/octo/ghast"}
        """
        let repo = try JSONDecoder().decode(GitHubRepository.self, from: Data(json.utf8))
        #expect(repo.runnerScope == .repository(fullName: "octo/ghast"))
    }
}
