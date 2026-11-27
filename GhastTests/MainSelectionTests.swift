import Testing
import Foundation
@testable import Ghast

@Suite struct MainSelectionTests {
    let org = RunnerScope.organization(login: "blackpaw-studio")

    func local(_ name: String) -> RunnerItem {
        RunnerItem(id: "id-\(name)", name: name, scope: org, labels: [], location: .thisMac(localID: "id-\(name)"), gitHubRunnerID: nil, status: .idle)
    }

    func remote(_ name: String, id: Int) -> RunnerItem {
        let runner = GitHubRunner(id: id, name: name, os: "Linux", status: "online", busy: false, labels: [])
        return RunnerItem(id: RunnerItem.remoteID(scope: org, gitHubRunnerID: id), name: name, scope: org, labels: [], location: .otherMachine(runner), gitHubRunnerID: id, status: .idle)
    }

    func catalog(_ thisMac: [RunnerItem], _ other: [RunnerItem] = []) -> RunnerCatalog {
        RunnerCatalog(thisMac: thisMac, otherMachines: other, stale: nil)
    }

    @Test func existingSelectionIsKept() {
        let now = catalog([local("a"), local("b")], [remote("r", id: 1)])
        #expect(MainSelection.runner("id-b").resolved(in: now, previous: now) == .runner("id-b"))
        #expect(MainSelection.runner(remote("r", id: 1).id).resolved(in: now, previous: now) == .runner(remote("r", id: 1).id))
    }

    @Test func nothingStoredSelectsTheFirstLocalRunner() {
        #expect(MainSelection?.none.resolved(in: catalog([local("a"), local("b")]), previous: nil) == .runner("id-a"))
    }

    @Test func vanishedRunnerFallsBackToTheNextLocalRunner() {
        let before = catalog([local("a"), local("b"), local("c")])
        let after = catalog([local("a"), local("c")])
        #expect(MainSelection.runner("id-b").resolved(in: after, previous: before) == .runner("id-c"))
    }

    @Test func vanishedLastRunnerFallsBackToTheNewLastLocalRunner() {
        let before = catalog([local("a"), local("b")])
        let after = catalog([local("a")])
        #expect(MainSelection.runner("id-b").resolved(in: after, previous: before) == .runner("id-a"))
    }

    @Test func vanishedRemoteRunnerFallsBackToTheFirstLocalRunner() {
        let before = catalog([local("a")], [remote("r", id: 1)])
        let after = catalog([local("a")])
        #expect(MainSelection.runner(remote("r", id: 1).id).resolved(in: after, previous: before) == .runner("id-a"))
    }

    @Test func noLocalRunnersGivesTheEmptyStateEvenWithRemoteRunners() {
        let before = catalog([local("a")], [remote("r", id: 1)])
        let after = catalog([], [remote("r", id: 1)])
        #expect(MainSelection.runner("id-a").resolved(in: after, previous: before) == .thisMacEmpty)
        #expect(MainSelection?.none.resolved(in: after, previous: nil) == .thisMacEmpty)
        #expect(MainSelection.thisMacEmpty.resolved(in: after, previous: after) == .thisMacEmpty)
    }

    @Test func emptyStateMovesToTheFirstLocalRunnerOnceOneExists() {
        #expect(MainSelection.thisMacEmpty.resolved(in: catalog([local("a")]), previous: catalog([])) == .runner("id-a"))
    }

    @Test(arguments: [MainSelection.thisMacEmpty, .runner("id-a"), .runner("remote:/orgs/x#3")])
    func selectionRoundTripsThroughSceneStorage(selection: MainSelection) {
        #expect(MainSelection(storageValue: selection.storageValue) == selection)
    }

    @Test func detailTabRoundTripsThroughItsRawValue() {
        #expect(DetailTab.allCases.map { DetailTab(rawValue: $0.rawValue) } == [.output, .configuration, .jobs])
    }

    // MARK: Detail tabs

    @Test func vmRunnersGetAJobsTabAfterConfiguration() {
        #expect(DetailTab.tabs(isVM: true) == [.output, .configuration, .jobs])
    }

    @Test func hostRunnersKeepTwoTabs() {
        #expect(DetailTab.tabs(isVM: false) == [.output, .configuration])
    }

    @Test func aSavedJobsTabShowsOutputForAHostRunner() {
        #expect(DetailTab.jobs.shown(isVM: false) == .output)
        #expect(DetailTab.jobs.shown(isVM: true) == .jobs)
        #expect(DetailTab.configuration.shown(isVM: false) == .configuration)
        #expect(DetailTab.output.shown(isVM: true) == .output)
    }
}
