import Testing
import Foundation
@testable import Ghast

@Suite struct RunnerCommandStateTests {
    let org = RunnerScope.organization(login: "blackpaw-studio")

    func local(_ status: RunnerDisplayStatus, gitHubRunnerID: Int? = 7) -> RunnerItem {
        RunnerItem(id: "a", name: "a", scope: org, labels: [], location: .thisMac(localID: "a"), gitHubRunnerID: gitHubRunnerID, status: status)
    }

    var remote: RunnerItem {
        let runner = GitHubRunner(id: 9, name: "r", os: "Linux", status: "online", busy: false, labels: [])
        return RunnerItem(id: RunnerItem.remoteID(scope: org, gitHubRunnerID: 9), name: "r", scope: org, labels: [], location: .otherMachine(runner), gitHubRunnerID: 9, status: .idle)
    }

    func state(_ selected: RunnerItem?, hasOutput: Bool = true, hasFindQuery: Bool = false, isSheetOpen: Bool = false) -> RunnerCommandState {
        RunnerCommandState(selected: selected, canStartAll: true, canStopAll: true, hasOutput: hasOutput, hasFindQuery: hasFindQuery, isSheetOpen: isSheetOpen)
    }

    @Test func runningRunnerCanStopAndRestartButNotStart() {
        let commands = state(local(.idle))
        #expect(!commands.isEnabled(.start))
        #expect(commands.isEnabled(.stop))
        #expect(commands.isEnabled(.restart))
    }

    @Test func stoppedRunnerCanOnlyStart() {
        let commands = state(local(.stopped(at: nil)))
        #expect(commands.isEnabled(.start))
        #expect(!commands.isEnabled(.stop))
        #expect(!commands.isEnabled(.restart))
    }

    @Test func remoteRunnerOnlyOffersGitHubAndGlobalCommands() {
        let commands = state(remote)
        let enabled = Set(RunnerCommand.allCases.filter(commands.isEnabled))
        #expect(enabled == [.openOnGitHub, .newRunner, .startAll, .stopAll])
    }

    @Test func emptyStateOffersOnlyGlobalCommands() {
        let enabled = Set(RunnerCommand.allCases.filter(state(nil).isEnabled))
        #expect(enabled == [.newRunner, .startAll, .stopAll])
    }

    @Test func outputCommandsNeedOutputAndFindNextNeedsAQuery() {
        let empty = state(local(.idle), hasOutput: false)
        #expect(!empty.isEnabled(.clearOutput))
        #expect(!empty.isEnabled(.copyAllOutput))
        #expect(empty.isEnabled(.find))
        #expect(!empty.isEnabled(.findNext))
        #expect(state(local(.idle), hasFindQuery: true).isEnabled(.findPrevious))
    }

    @Test func openOnGitHubNeedsTheRunnersGitHubID() {
        #expect(!state(local(.idle, gitHubRunnerID: nil)).isEnabled(.openOnGitHub))
    }

    /// With a sheet up nothing applies, so ⌘. reaches the sheet's Cancel.
    @Test func sheetDisablesEveryCommand() {
        let commands = state(local(.idle), isSheetOpen: true)
        #expect(RunnerCommand.allCases.filter(commands.isEnabled).isEmpty)
    }

    @Test(arguments: [RunnerDisplayStatus.idle, .stopped(at: nil), .starting])
    func localRunnerCanBeReconfiguredAndRemovedInAnyState(status: RunnerDisplayStatus) {
        let commands = state(local(status))
        #expect(commands.isEnabled(.reconfigure))
        #expect(commands.isEnabled(.remove))
    }

    /// One Remove or Reconfigure at a time per runner, and no lifecycle change under it: a
    /// Start during Reconfigure would run the runner while its registration is set aside.
    @Test(arguments: [RunnerDisplayStatus.idle, .stopped(at: nil)])
    func runningFlowDisablesLifecycleReconfigureAndRemove(status: RunnerDisplayStatus) {
        var commands = state(local(status))
        commands.isFlowBusy = true
        for command in [RunnerCommand.start, .stop, .restart, .reconfigure, .remove] {
            #expect(!commands.isEnabled(command), "\(command)")
        }
        #expect(commands.isEnabled(.showOutput))
    }
}
