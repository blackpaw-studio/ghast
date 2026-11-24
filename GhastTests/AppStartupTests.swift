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

    /// Launch applies the saved cap (which evicts) and sweeps before VM runners restart.
    @Test func startingServicesAppliesTheCacheCapThenSweeps() async {
        let api = MockGitHubAPIService()
        let store = FakeCacheMaintainer()
        let settings = AppSettings(defaults: makeIsolatedDefaults().defaults)
        settings.cacheSizeCapGB = 7
        let dependencies = AppDependencies(
            runnerService: makeTestRunnerService(),
            apiService: api,
            authService: GitHubAuthService(apiService: api, tokenStore: InMemoryTokenStore()),
            settings: settings,
            localCache: LocalCache(store: store, makeServer: { FakeLocalCache() }, sleeper: { _ in throw CancellationError() })
        )

        await dependencies.startServices()

        #expect(await store.calls == ["setCap 7000000000", "sweep"])
    }

    @Test func quittingStopsTheCacheServerThenSavesTheIndex() async {
        let api = MockGitHubAPIService()
        let store = FakeCacheMaintainer()
        let server = FakeLocalCache()
        let cache = LocalCache(store: store, makeServer: { server }, sleeper: { _ in throw CancellationError() })
        _ = cache.server()
        let delegate = AppDelegate(dependencies: AppDependencies(
            runnerService: makeTestRunnerService(),
            apiService: api,
            authService: GitHubAuthService(apiService: api, tokenStore: InMemoryTokenStore()),
            settings: AppSettings(defaults: makeIsolatedDefaults().defaults),
            localCache: cache
        ))

        await delegate.prepareForQuit()

        #expect(server.isStopped)
        #expect(await store.calls == ["flush"])
    }
}
