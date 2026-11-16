import Testing
import Foundation
@testable import Ghast

@Suite struct RefreshSchedulerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// A scheduler whose last fetch began at `start` and succeeded.
    func afterOneSuccess() -> RefreshScheduler {
        var scheduler = RefreshScheduler()
        scheduler.didStart(at: start)
        scheduler.didSucceed()
        return scheduler
    }

    // MARK: Cadence

    @Test func launchFetchesImmediately() {
        #expect(RefreshScheduler().shouldRefresh(.launch, now: start, isVisible: false))
    }

    @Test func activationIsThrottledToOnceEvery15Seconds() {
        let scheduler = afterOneSuccess()
        #expect(!scheduler.shouldRefresh(.activation, now: at(14), isVisible: true))
        #expect(scheduler.shouldRefresh(.activation, now: at(15), isVisible: true))
    }

    @Test func pollRunsEvery60SecondsWhileVisible() {
        let scheduler = afterOneSuccess()
        #expect(!scheduler.shouldRefresh(.poll, now: at(59), isVisible: true))
        #expect(scheduler.shouldRefresh(.poll, now: at(60), isVisible: true))
    }

    @Test func pollNeverRunsWhileHiddenOrOccluded() {
        let scheduler = afterOneSuccess()
        #expect(!scheduler.shouldRefresh(.poll, now: at(3_600), isVisible: false))
    }

    @Test func explicitRefreshIgnoresTheCadence() {
        let scheduler = afterOneSuccess()
        #expect(scheduler.shouldRefresh(.explicit, now: at(1), isVisible: false))
    }

    // MARK: Backoff

    @Test func repeatedFailuresBackOffThenSuccessResets() {
        var scheduler = RefreshScheduler()
        var now = start
        for expected: TimeInterval in [60, 120, 240, 600, 600] {
            scheduler.didStart(at: now)
            scheduler.didFail(retryAt: nil)
            #expect(!scheduler.shouldRefresh(.poll, now: now.addingTimeInterval(expected - 1), isVisible: true))
            #expect(!scheduler.shouldRefresh(.activation, now: now.addingTimeInterval(expected - 1), isVisible: true))
            #expect(scheduler.shouldRefresh(.poll, now: now.addingTimeInterval(expected), isVisible: true))
            now = now.addingTimeInterval(expected)
        }
        scheduler.didStart(at: now)
        scheduler.didSucceed()
        #expect(scheduler.shouldRefresh(.poll, now: now.addingTimeInterval(60), isVisible: true))
        #expect(scheduler.shouldRefresh(.activation, now: now.addingTimeInterval(15), isVisible: true))
    }

    // MARK: Rate limits

    @Test(arguments: [RefreshScheduler.Trigger.launch, .activation, .poll, .explicit])
    func rateLimitSkipsEveryTriggerUntilTheResetTime(trigger: RefreshScheduler.Trigger) {
        var scheduler = RefreshScheduler()
        scheduler.didStart(at: start)
        scheduler.didFail(retryAt: at(900))
        #expect(!scheduler.shouldRefresh(trigger, now: at(899), isVisible: true))
        #expect(scheduler.shouldRefresh(trigger, now: at(900), isVisible: true))
    }

    @Test func rateLimitErrorGivesItsRetryDate() {
        let now = start
        #expect(GitHubAPIError.rateLimited(status: 429, retryAfter: 30, resetAt: nil).retryDate(now: now) == at(30))
        #expect(GitHubAPIError.rateLimited(status: 403, retryAfter: nil, resetAt: at(500)).retryDate(now: now) == at(500))
        // No header at all: GitHub asks clients to wait at least a minute.
        #expect(GitHubAPIError.rateLimited(status: 429, retryAfter: nil, resetAt: nil).retryDate(now: now) == at(60))
        #expect(GitHubAPIError.serverError(502).retryDate(now: now) == nil)
    }
}

@MainActor @Suite struct RemoteRunnerStoreTests {
    let org = GitHubOrganization(login: "blackpaw-studio", id: 10, avatarURL: "")
    let otherOrg = GitHubOrganization(login: "elsewhere", id: 11, avatarURL: "")
    let repoScope = RunnerScope.repository(fullName: "blackpaw-studio/ghast")
    let runner = GitHubRunner(id: 1, name: "helios-linux", os: "Linux", status: "online", busy: false, labels: [])

    func makeStore(
        orgs: [GitHubOrganization],
        localScopes: [RunnerScope] = [],
        configure: (MockGitHubAPIService) -> Void = { _ in }
    ) -> (RemoteRunnerStore, MockGitHubAPIService, FakeClock) {
        let api = MockGitHubAPIService()
        api.mockOrganizations = orgs
        api.mockRunners = [runner]
        configure(api)
        let clock = FakeClock()
        let store = RemoteRunnerStore(api: api, clock: clock, localScopes: { localScopes })
        return (store, api, clock)
    }

    @Test func scopesAreAdminOrgsPlusLocalRunnerScopes() async {
        let (store, api, _) = makeStore(orgs: [org], localScopes: [repoScope, .organization(login: org.login)])

        await store.refresh(.launch)

        #expect(Set(store.fetches.keys) == [.organization(login: org.login), repoScope])
        #expect(api.runnerFetches.count == 2)
    }

    @Test(arguments: [GitHubAPIError.httpStatus(403), .notFound])
    func forbiddenOrMissingOrgIsRecordedAsNeedingOwnerAccess(error: GitHubAPIError) async {
        let (store, _, _) = makeStore(orgs: [org, otherOrg]) { api in
            api.runnerErrors[.organization(login: "elsewhere")] = error
        }

        await store.refresh(.launch)

        #expect(store.needsOwnerAccess == ["elsewhere"])
        #expect(store.fetches[.organization(login: "elsewhere")] == nil)
        #expect(store.fetches[.organization(login: org.login)] != nil)
    }

    @Test func failedScopeKeepsItsLastGoodList() async {
        let (store, api, clock) = makeStore(orgs: [org])
        await store.refresh(.launch)
        api.runnerErrors[.organization(login: org.login)] = GitHubAPIError.networkError(URLError(.notConnectedToInternet))
        clock.advance(by: 60)

        await store.refresh(.explicit)

        guard case let .failed(_, lastGood)? = store.fetches[.organization(login: org.login)] else {
            Issue.record("expected a failed fetch")
            return
        }
        #expect(lastGood?.runners.map(\.name) == ["helios-linux"])
    }

    @Test func rateLimitBlocksFurtherRefreshesUntilReset() async {
        let (store, api, clock) = makeStore(orgs: [org]) { api in
            api.runnerErrors[.organization(login: "blackpaw-studio")] = GitHubAPIError.rateLimited(status: 429, retryAfter: 120, resetAt: nil)
        }
        await store.refresh(.launch)
        let fetchesAfterLaunch = api.runnerFetches.count

        clock.advance(by: 119)
        await store.refresh(.explicit)
        #expect(api.runnerFetches.count == fetchesAfterLaunch)

        clock.advance(by: 1)
        await store.refresh(.explicit)
        #expect(api.runnerFetches.count == fetchesAfterLaunch + 1)
    }

    @Test func hiddenWindowDoesNotPoll() async {
        let (store, api, clock) = makeStore(orgs: [org])
        await store.refresh(.launch)
        clock.advance(by: 600)

        store.isVisible = false
        await store.refresh(.poll)
        #expect(api.runnerFetches.count == 1)

        store.isVisible = true
        await store.refresh(.poll)
        #expect(api.runnerFetches.count == 2)
    }
}
