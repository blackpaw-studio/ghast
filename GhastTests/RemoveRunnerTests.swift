import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct RemoveRunnerTests {
    let h = FlowHarness()

    /// A registered runner on this Mac with its folder on disk, running.
    func runningRunner(_ name: String = "dionysus-3") async throws -> LocalRunner {
        let folder = h.folder(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runner = LocalRunner(name: name, scope: FlowHarness.org, path: folder.path, labels: ["self-hosted", "macOS", "ARM64"])
        h.service.addLocalRunner(runner)
        try await h.service.startRunner(id: runner.id)
        return runner
    }

    var remover: RunnerRemover { h.services.remover }

    @Test func removesInOrderStopTokenConfigTrashThenList() async throws {
        let runner = try await runningRunner()
        var stoppedWhenTokenRequested = false
        h.api.onRemoveToken = { stoppedWhenTokenRequested = h.service.processStates[runner.id] == .stopped }

        #expect(try await remover.remove(runner, gitHubRunnerID: 1002) == .removed)

        #expect(stoppedWhenTokenRequested)
        #expect(Array(h.log.all.suffix(3)) == ["remove-token blackpaw-studio", "config remove dionysus-3", "trash dionysus-3"])
        #expect(await h.scripts.calls.last?.arguments == ["./config.sh", "remove", "--token", "RM"])
        #expect(h.service.localRunners.isEmpty)
    }

    @Test func failedConfigRemoveFallsBackToDeleteByID() async throws {
        let runner = try await runningRunner()
        await h.scripts.set(remove: ScriptResult(status: 1, output: "Failed: Removing runner from the server"))

        #expect(try await remover.remove(runner, gitHubRunnerID: 1002) == .removed)

        #expect(Array(h.log.all.suffix(4)) == ["remove-token blackpaw-studio", "config remove dionysus-3", "delete 1002 blackpaw-studio", "trash dionysus-3"])
        #expect(h.service.localRunners.isEmpty)
    }

    @Test func fallbackFindsTheIDByNameWhenItIsUnknown() async throws {
        let runner = try await runningRunner()
        h.api.removeTokenError = GitHubAPIError.serverError(502)
        h.api.runners[FlowHarness.org] = [
            GitHubRunner(id: 5, name: "helios-linux", os: "Linux", status: "online", busy: false, labels: []),
            GitHubRunner(id: 77, name: "Dionysus-3", os: "macOS", status: "offline", busy: false, labels: []),
        ]

        #expect(try await remover.remove(runner, gitHubRunnerID: nil) == .removed)

        #expect(Array(h.log.all.suffix(3)) == ["runners blackpaw-studio", "delete 77 blackpaw-studio", "trash dionysus-3"])
    }

    @Test func aRunnerGitHubNoLongerListsCountsAsUnregistered() async throws {
        let runner = try await runningRunner()
        await h.scripts.set(remove: ScriptResult(status: 1, output: "Failed: runner not found"))

        #expect(try await remover.remove(runner, gitHubRunnerID: nil) == .removed)
        #expect(h.trasher.trashed.map(\.lastPathComponent) == ["dionysus-3"])
    }

    @Test func aDeleteThatFindsNothingCountsAsUnregistered() async throws {
        let runner = try await runningRunner()
        await h.scripts.set(remove: ScriptResult(status: 1, output: "Failed"))
        h.api.deleteError = GitHubAPIError.notFound

        #expect(try await remover.remove(runner, gitHubRunnerID: 1002) == .removed)
    }

    @Test func gitHubFailureAsksFirstAndTrashesNothing() async throws {
        let runner = try await runningRunner()
        h.api.removeTokenError = GitHubAPIError.httpStatus(403)
        h.api.deleteError = GitHubAPIError.httpStatus(403)

        let outcome = try await remover.remove(runner, gitHubRunnerID: 1002)

        #expect(outcome == .needsLocalOnlyConfirmation(reason: "You need to be an owner of blackpaw-studio to manage its runners."))
        #expect(h.trasher.trashed.isEmpty)
        #expect(h.service.localRunners.map(\.id) == [runner.id])
        #expect(h.service.processStates[runner.id] == .stopped)
    }

    @Test func confirmedLocalOnlyRemovalTrashesAndDrops() async throws {
        let runner = try await runningRunner()

        try await remover.removeFromThisMacOnly(runner)

        #expect(!h.log.all.contains { $0.hasPrefix("remove-token") || $0.hasPrefix("delete") })
        #expect(h.trasher.trashed.map(\.lastPathComponent) == ["dionysus-3"])
        #expect(h.service.localRunners.isEmpty)
    }

    @Test func aFolderThatCannotBeTrashedKeepsTheRunnerListed() async throws {
        let runner = try await runningRunner()
        h.trasher.failure = CocoaError(.fileWriteNoPermission)

        await #expect(throws: CocoaError.self) { try await remover.remove(runner, gitHubRunnerID: 1002) }
        #expect(h.service.localRunners.map(\.id) == [runner.id])
    }

    @Test func aMissingFolderIsDroppedWithoutTrashing() async throws {
        let runner = LocalRunner(name: "gone", scope: FlowHarness.org, path: h.folder("gone").path)
        h.service.addLocalRunner(runner)

        #expect(try await remover.remove(runner, gitHubRunnerID: nil) == .removed)
        #expect(h.trasher.trashed.isEmpty)
        #expect(h.service.localRunners.isEmpty)
    }

    @Test func removeFromGitHubDeletesByID() async throws {
        try await remover.removeFromGitHub(gitHubRunnerID: 1003, scope: FlowHarness.org)
        #expect(h.log.all == ["delete 1003 blackpaw-studio"])
    }

    @Test func removeFromGitHubFailureIsReported() async throws {
        h.api.deleteError = GitHubAPIError.serverError(500)
        await #expect(throws: GitHubAPIError.self) {
            try await remover.removeFromGitHub(gitHubRunnerID: 1003, scope: FlowHarness.org)
        }
    }

    // MARK: Tart VM runners

    /// A VM runner whose slot is mid-job, with its folder (holding only the log) on disk.
    func runningVMRunner(_ name: String = "dionysus-3") async throws -> LocalRunner {
        let folder = h.folder(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var runner = LocalRunner(name: name, scope: FlowHarness.org, path: folder.path, labels: ["self-hosted", "macOS", "ARM64"])
        runner.backend = .tart(image: FlowHarness.tartImage)
        h.service.addLocalRunner(runner)
        try await h.service.startRunner(id: runner.id)
        #expect(await eventually { h.tart.jobsStarted == 1 })
        return runner
    }

    @Test func removingAVMRunnerStopsTheSlotAndNeverUnregisters() async throws {
        let runner = try await runningVMRunner()
        let vm = try #require(h.tart.currentJobVM)

        #expect(try await remover.remove(runner, gitHubRunnerID: nil) == .removed)

        let log = h.log.all
        #expect(log.contains("stop \(vm)"))
        #expect(log.contains("delete \(vm)"))
        // The slot deleted its own JIT registration; no registration token, config.sh or lookup.
        #expect(!log.contains { $0.hasPrefix("remove-token") || $0.hasPrefix("config") || $0.hasPrefix("runners ") })
        #expect(await h.scripts.calls.isEmpty)
        #expect(h.trasher.trashed.map(\.lastPathComponent) == ["dionysus-3"])
        #expect(h.service.localRunners.isEmpty)
        #expect(!h.service.hasRunningProcesses)
        // Its scale set on GitHub goes too.
        #expect(h.demand.source(runner)?.deleteRemoteCount == 1)
    }

    @Test func aVMRunnerWhoseScaleSetCannotBeDeletedAsksToRemoveLocallyOnly() async throws {
        let runner = try await runningVMRunner()
        h.demand.deleteRemoteError = ScaleSetError.transient("HTTP 502")

        let outcome = try await remover.remove(runner, gitHubRunnerID: nil)

        guard case .needsLocalOnlyConfirmation = outcome else { Issue.record("got \(outcome)"); return }
        #expect(h.service.localRunners.map(\.id) == [runner.id])
        #expect(h.trasher.trashed.isEmpty)
        #expect(!h.service.hasRunningProcesses)
    }

    @Test func aFailedGitHubDeleteNeverBlocksRemovingAVMRunner() async throws {
        let runner = try await runningVMRunner()
        h.api.deleteError = GitHubAPIError.httpStatus(403)

        #expect(try await remover.remove(runner, gitHubRunnerID: nil) == .removed)
        #expect(h.service.localRunners.isEmpty)
    }
}

