import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct AppStartupTests {
    /// Launch starts services before the stored token is applied, so a GitHub fetch there
    /// would run unauthenticated. The main window fetches once the account is signed in.
    @Test func startingServicesMakesNoGitHubRequestBeforeSignIn() async {
        let api = MockGitHubAPIService()
        api.mockOrganizations = [GitHubOrganization(login: "blackpaw-studio", id: 1, avatarURL: "")]
        let dependencies = AppDependencies(
            runnerService: makeTestRunnerService(),
            apiService: api,
            authService: GitHubAuthService(apiService: api, tokenStore: InMemoryTokenStore()),
            settings: AppSettings(defaults: makeIsolatedDefaults().defaults)
        )

        await dependencies.startServices()

        #expect(api.runnerFetches.isEmpty)
    }
}
