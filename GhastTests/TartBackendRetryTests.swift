import Testing
import Foundation
@testable import Ghast

/// Which VM-run errors are worth another try, how long the runner waits, and which end it.
@Suite("TartBackend retries")
@MainActor
struct TartBackendRetryTests {
    private static let offline = URLError(.notConnectedToInternet)

    private func hasExited(_ h: TartHarness, _ runner: LocalRunner) -> Bool {
        if case .exited? = h.state(runner) { return true }
        return false
    }

    @Test("a network blip fetching the runner package is retried after the restart delay, and the runner stays on")
    func networkBlipIsRetried() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.api.applicationsFailures = [Self.offline]
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.sleeps.all == [.seconds(5)])
        #expect(h.service.localRunners.first?.shouldBeRunning == true)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("the wait doubles with each consecutive failure up to a minute, and the runner stays on")
    func backoffKeepsTrying() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.api.applicationsFailures = Array(repeating: Self.offline, count: 6)
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.sleeps.all == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60)])
        #expect(h.log.all.filter { $0 == "applications" }.count == 7)
        #expect(h.service.localRunners.first?.shouldBeRunning == true)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a GitHub 5xx while registering is retried with a fresh VM, and the first VM is cleaned up")
    func jitServerErrorIsRetried() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.api.jitFailures = [GitHubAPIError.serverError(502)]
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.log.all.contains("delete \(h.vmName(runner, iteration: 1))"))
        #expect(h.cli.currentJobVM == h.vmName(runner, iteration: 2))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a tart list failure is retried")
    func tartListFailureIsRetried() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.listFailures = [TartError.commandFailed(command: "list", status: 1, detail: "boom")]
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.sleeps.all == [.seconds(5)])
        await h.service.stopRunner(id: runner.id)
    }

    @Test("one boot timeout is retried")
    func bootTimeoutIsRetried() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        // 91 probes fit in the 180 s boot timeout at one per 2 s; the next iteration's first answers.
        h.cli.failedProbesBeforeReady = 91
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(h.log.all.contains("delete \(h.vmName(runner, iteration: 1))"))
        #expect(h.cli.currentJobVM == h.vmName(runner, iteration: 2))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a successful job resets the failure count")
    func successResetsTheCount() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.api.applicationsFailures = [Self.offline, Self.offline]
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        h.api.applicationsFailures = [Self.offline]
        try await h.nextJob(runner)

        #expect(await h.settled { h.cli.jobsStarted == 2 })
        // The first failure after a job waits the first step again.
        #expect(h.sleeps.all == [.seconds(5), .seconds(10), .seconds(5)])
        #expect(!hasExited(h, runner))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("configuration errors stay fatal: no retry, no wait", arguments: [
        GitHubAPIError.unauthorized, GitHubAPIError.notFound, GitHubAPIError.httpStatus(422),
    ])
    func configurationErrorsAreFatal(error: GitHubAPIError) async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.api.jitFailures = [error]
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)

        #expect(await h.settled { hasExited(h, runner) })
        #expect(h.log.all.filter { $0.hasPrefix("jit ") }.count == 1)
        #expect(h.sleeps.all.isEmpty)
        #expect(h.service.localRunners.first?.shouldBeRunning == false)
    }

    @Test("a missing runner group from the demand source stays fatal")
    func missingGroupIsFatal() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let runner = h.addRunner(scope: .organization(login: "acme"), group: "nope")

        try await h.service.startRunner(id: runner.id)
        let source = try #require(h.demand.source(runner))
        #expect(await h.settled { source.isRunning })
        source.failRun(TartBackendError.runnerGroupNotFound("nope"))

        #expect(await h.settled { hasExited(h, runner) })
        #expect(!h.log.all.contains { $0.hasPrefix("clone ") })
        #expect(h.sleeps.all.isEmpty)
        #expect(h.lines.lines.contains { $0.contains("\"nope\" does not exist") })
    }
}
