import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct RepositoryCatalogTests {
    let api = MockGitHubAPIService()
    let clock = FakeClock()

    func makeCatalog() -> RepositoryCatalog {
        RepositoryCatalog(api: api, clock: clock)
    }

    func repo(_ id: Int, _ fullName: String) -> GitHubRepository {
        let owner = String(fullName.split(separator: "/")[0])
        return GitHubRepository(
            id: id,
            name: String(fullName.split(separator: "/")[1]),
            fullName: fullName,
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: id, login: owner, avatarURL: "", name: nil, email: nil),
            htmlURL: "https://github.com/\(fullName)",
            permissions: RepositoryPermissions(admin: true)
        )
    }

    /// Yields until `condition` holds; the catalog's work runs on the main actor too.
    func settle(until condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    @Test func firstLoadFetchesAndPublishesTheList() async {
        api.mockRepositories = [repo(1, "octo/ghast")]
        let catalog = makeCatalog()

        await catalog.load(account: "octo")

        #expect(catalog.repositories?.map(\.fullName) == ["octo/ghast"])
        #expect(catalog.status == .loaded)
        #expect(api.repositoryFetchCount == 1)
    }

    @Test func showsLoadingWhileTheFirstFetchIsInFlight() async {
        api.holdsRepositoriesPending = true
        let catalog = makeCatalog()

        let load = Task { await catalog.load(account: "octo") }
        await settle { api.repositoryFetchCount == 1 }

        #expect(catalog.status == .loading)
        #expect(catalog.repositories == nil)
        api.releasePendingRequests()
        await load.value
        #expect(catalog.status == .loaded)
    }

    @Test func reopeningInsideTheCacheWindowMakesNoRequest() async {
        let catalog = makeCatalog()
        await catalog.load(account: "octo")

        clock.advance(by: RepositoryCatalog.freshness - 1)
        await catalog.load(account: "octo")

        #expect(api.repositoryFetchCount == 1)
    }

    @Test func reopeningAfterTheWindowKeepsTheCachedListWhileRefreshing() async {
        api.mockRepositories = [repo(1, "octo/old")]
        let catalog = makeCatalog()
        await catalog.load(account: "octo")
        clock.advance(by: RepositoryCatalog.freshness + 1)
        api.mockRepositories = [repo(2, "octo/new")]
        api.holdsRepositoriesPending = true

        let refresh = Task { await catalog.load(account: "octo") }
        await settle { api.repositoryFetchCount == 2 }

        #expect(catalog.repositories?.map(\.fullName) == ["octo/old"])
        #expect(catalog.status == .loading)
        api.releasePendingRequests()
        await refresh.value
        #expect(catalog.repositories?.map(\.fullName) == ["octo/new"])
    }

    @Test func overlappingLoadsShareOneRequest() async {
        api.holdsRepositoriesPending = true
        let catalog = makeCatalog()

        let first = Task { await catalog.load(account: "octo") }
        let second = Task { await catalog.load(account: "octo") }
        await settle { api.repositoryFetchCount >= 1 }
        for _ in 0..<50 { await Task.yield() }
        api.releasePendingRequests()
        await first.value
        await second.value

        #expect(api.repositoryFetchCount == 1)
        #expect(catalog.status == .loaded)
    }

    @Test func aFailedFirstLoadReportsTheErrorAndRetryFetchesAgain() async {
        api.shouldThrowError = true
        let catalog = makeCatalog()

        await catalog.load(account: "octo")

        guard case let .failed(message) = catalog.status else {
            Issue.record("expected a failure, got \(catalog.status)")
            return
        }
        #expect(!message.isEmpty)
        #expect(catalog.repositories == nil)

        api.shouldThrowError = false
        api.mockRepositories = [repo(1, "octo/ghast")]
        await catalog.retry(account: "octo")

        #expect(api.repositoryFetchCount == 2)
        #expect(catalog.status == .loaded)
        #expect(catalog.repositories?.count == 1)
    }

    @Test func aFailedRefreshKeepsTheLastGoodList() async {
        api.mockRepositories = [repo(1, "octo/ghast")]
        let catalog = makeCatalog()
        await catalog.load(account: "octo")
        clock.advance(by: RepositoryCatalog.freshness + 1)
        api.shouldThrowError = true

        await catalog.load(account: "octo")

        #expect(catalog.repositories?.map(\.fullName) == ["octo/ghast"])
    }

    @Test func anotherAccountNeverSeesThePreviousAccountsList() async {
        api.mockRepositories = [repo(1, "octo/private")]
        let catalog = makeCatalog()
        await catalog.load(account: "octo")
        api.mockRepositories = []
        api.holdsRepositoriesPending = true

        let load = Task { await catalog.load(account: "someone-else") }
        await settle { api.repositoryFetchCount == 2 }

        #expect(catalog.repositories == nil)
        api.releasePendingRequests()
        await load.value
        #expect(catalog.repositories?.isEmpty == true)
    }
}
