import Testing
import Foundation
@testable import Ghast

/// Remove, Reconfigure and Remove from GitHub always go through a confirmation first, and a
/// refused GitHub step offers Remove from This Mac Only.
@MainActor @Suite struct RunnerFlowCoordinatorTests {
    let h = FlowHarness()
    let refreshes = CallLog()

    func coordinator() -> RunnerFlowCoordinator {
        let refreshes = refreshes
        return RunnerFlowCoordinator(services: h.services, refreshRemote: { refreshes.append("refresh") })
    }

    func runner(_ name: String = "dionysus-3") throws -> LocalRunner {
        let folder = h.folder(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runner = LocalRunner(name: name, scope: FlowHarness.org, path: folder.path, labels: ["self-hosted", "macOS", "ARM64"])
        h.service.addLocalRunner(runner)
        return runner
    }

    @Test func removeAsksBeforeDoingAnything() throws {
        let runner = try runner()
        let flows = coordinator()

        flows.requestRemove(localID: runner.id, gitHubRunnerID: 1002)

        #expect(flows.prompt == .confirmRemove(runner, gitHubRunnerID: 1002))
        #expect(h.log.all.isEmpty)
        #expect(h.service.localRunners.count == 1)
    }

    @Test func dismissingTheConfirmationChangesNothing() throws {
        let runner = try runner()
        let flows = coordinator()
        flows.requestRemove(localID: runner.id, gitHubRunnerID: 1002)

        flows.dismiss()

        #expect(flows.prompt == nil)
        #expect(h.log.all.isEmpty)
        #expect(h.service.localRunners.count == 1)
    }

    @Test func confirmedRemoveRemovesAndRefreshes() async throws {
        let runner = try runner()
        let flows = coordinator()
        flows.requestRemove(localID: runner.id, gitHubRunnerID: 1002)

        await flows.confirm(try #require(flows.prompt))

        #expect(flows.prompt == nil)
        #expect(h.service.localRunners.isEmpty)
        #expect(h.log.all.contains("trash dionysus-3"))
        #expect(refreshes.all == ["refresh"])
        #expect(!flows.isBusy(runner.id))
    }

    /// An alert clears its binding as its button fires, before the confirmed work runs.
    @Test func confirmRunsEvenAfterTheAlertClearedThePrompt() async throws {
        let runner = try runner()
        let flows = coordinator()
        flows.requestRemove(localID: runner.id, gitHubRunnerID: 1002)
        let shown = try #require(flows.prompt)

        flows.dismiss()
        await flows.confirm(shown)

        #expect(h.service.localRunners.isEmpty)
    }

    @Test func refusedGitHubStepOffersRemoveFromThisMacOnly() async throws {
        let runner = try runner()
        h.api.removeTokenError = GitHubAPIError.httpStatus(403)
        h.api.deleteError = GitHubAPIError.httpStatus(403)
        let flows = coordinator()
        flows.requestRemove(localID: runner.id, gitHubRunnerID: 1002)

        await flows.confirm(try #require(flows.prompt))

        let reason = "You need to be an owner of blackpaw-studio to manage its runners."
        #expect(flows.prompt == .confirmRemoveLocalOnly(runner, reason: reason))
        #expect(h.service.localRunners.count == 1)
        #expect(!h.log.all.contains { $0.hasPrefix("trash") })

        await flows.confirm(try #require(flows.prompt))

        #expect(flows.prompt == nil)
        #expect(h.service.localRunners.isEmpty)
        #expect(h.log.all.last == "trash dionysus-3")
    }

    @Test func reconfigureAsksThenReregistersWithReplace() async throws {
        let runner = try runner()
        let flows = coordinator()

        flows.requestReconfigure(localID: runner.id)
        #expect(flows.prompt == .confirmReconfigure(runner))
        #expect(h.log.all.isEmpty)

        await flows.confirm(try #require(flows.prompt))

        #expect(flows.prompt == nil)
        #expect(await h.scripts.calls.last?.arguments.contains("--replace") == true)
    }

    @Test func failedReconfigureReportsTheError() async throws {
        let runner = try runner()
        h.api.registrationTokenError = GitHubAPIError.serverError(502)
        let flows = coordinator()
        flows.requestReconfigure(localID: runner.id)

        await flows.confirm(try #require(flows.prompt))

        guard case let .failure(title, _) = flows.prompt else {
            Issue.record("expected a failure prompt, got \(String(describing: flows.prompt))")
            return
        }
        #expect(title == "Couldn't Reconfigure “dionysus-3”")
        #expect(h.service.localRunners.count == 1)
    }

    @Test func removeFromGitHubAsksThenDeletesByIDAndRefreshes() async throws {
        let flows = coordinator()

        flows.requestRemoveFromGitHub(name: "helios-linux", scope: FlowHarness.org, gitHubRunnerID: 1003)
        #expect(flows.prompt == .confirmRemoveFromGitHub(name: "helios-linux", scope: FlowHarness.org, gitHubRunnerID: 1003))
        #expect(h.log.all.isEmpty)

        await flows.confirm(try #require(flows.prompt))

        #expect(h.log.all == ["delete 1003 blackpaw-studio"])
        #expect(refreshes.all == ["refresh"])
        #expect(flows.prompt == nil)
    }

    @Test func aRunnerAlreadyGoneAsksNothing() {
        let flows = coordinator()
        flows.requestRemove(localID: "missing", gitHubRunnerID: nil)
        flows.requestReconfigure(localID: "missing")
        #expect(flows.prompt == nil)
    }
}
