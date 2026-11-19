import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct RESTPollingDemandSourceTests {
    let api = MockGitHubAPIService()
    let sleeper = ManualSleeper()
    let demand = DemandRecorder()

    private func makeSource() -> RESTPollingDemandSource {
        RESTPollingDemandSource(repo: "octo/ghast", runnerName: "Mac-VM", api: api, sleeper: sleeper.sleeper)
    }

    private func job(_ id: Int, _ status: String, _ labels: [String]) -> GitHubWorkflowJob {
        GitHubWorkflowJob(id: id, status: status, labels: labels)
    }

    /// Starts `run` and waits for `polls` demand reports.
    private func start(_ source: RESTPollingDemandSource, polls: Int = 1) async -> Task<Void, any Error> {
        let recorder = demand
        let task = Task { try await source.run(recorder.context) }
        while demand.values.count < polls { await Task.yield() }
        return task
    }

    @Test("demand counts queued and running jobs that ask for the runner's name, ignoring case")
    func countsMatchingJobs() async throws {
        api.workflowRuns["queued"] = .fresh([GitHubWorkflowRun(id: 1, status: "queued")], etag: "rq")
        api.workflowRuns["in_progress"] = .fresh([GitHubWorkflowRun(id: 2, status: "in_progress")], etag: "rp")
        api.workflowJobs[1] = .fresh([job(10, "queued", ["mac-vm"]), job(11, "queued", ["ubuntu-latest"])], etag: "j1")
        api.workflowJobs[2] = .fresh([job(20, "in_progress", ["MAC-VM"]), job(21, "completed", ["mac-vm"]), job(22, "queued", ["mac-vm"])], etag: "j2")

        let task = await start(makeSource())
        task.cancel()
        sleeper.wakeAll()
        _ = await task.result

        #expect(demand.values == [3])
        #expect(sleeper.requested == [.seconds(15)])
    }

    @Test("polling reports no job queue, once")
    func reportsNoQueue() async throws {
        let task = await start(makeSource(), polls: 1)
        sleeper.wakeAll()
        while demand.values.count < 2 { await Task.yield() }
        task.cancel()
        sleeper.wakeAll()
        _ = await task.result

        #expect(demand.queue == [.noQueue])
    }

    @Test("the next poll sends each URL's ETag and keeps what a 304 did not change")
    func etags() async throws {
        api.workflowRuns["queued"] = .fresh([GitHubWorkflowRun(id: 1, status: "queued")], etag: "rq")
        api.workflowJobs[1] = .fresh([job(10, "queued", ["mac-vm"])], etag: "j1")
        let task = await start(makeSource())

        api.workflowRuns["queued"] = .notModified
        api.workflowRuns["in_progress"] = .notModified
        api.workflowJobs[1] = .notModified
        sleeper.wakeAll()
        while demand.values.count < 2 { await Task.yield() }
        task.cancel()
        sleeper.wakeAll()
        _ = await task.result

        #expect(demand.values == [1, 1])
        let second = api.conditionalFetches.suffix(3)
        #expect(second.map(\.key) == ["runs:queued", "runs:in_progress", "jobs:1"])
        #expect(second.map(\.etag) == ["rq", nil, "j1"])
    }

    @Test("a run that drops out of the lists stops counting")
    func finishedRunDropsOut() async throws {
        api.workflowRuns["queued"] = .fresh([GitHubWorkflowRun(id: 1, status: "queued")], etag: nil)
        api.workflowJobs[1] = .fresh([job(10, "queued", ["mac-vm"])], etag: nil)
        let task = await start(makeSource())
        api.workflowRuns["queued"] = .fresh([], etag: nil)
        sleeper.wakeAll()
        while demand.values.count < 2 { await Task.yield() }
        task.cancel()
        sleeper.wakeAll()
        _ = await task.result
        #expect(demand.values == [1, 0])
    }

    @Test("a poll failure is thrown for the caller's backoff")
    func failure() async throws {
        api.workflowError = GitHubAPIError.serverError(502)
        await #expect(throws: GitHubAPIError.self) { try await makeSource().run(demand.context) }
    }

    @Test("a JIT runner is registered in the Default group with the runner's name as a label")
    func jit() async throws {
        let recording = FlowGitHubAPI(log: CallLog())
        let source = RESTPollingDemandSource(repo: "octo/ghast", runnerName: "Mac-VM", api: recording, sleeper: sleeper.sleeper)
        _ = try await source.jitConfig(runnerName: "Mac-VM-a1b2c3", workFolder: "_work")
        let request = try #require(recording.jitRequests.first)
        #expect(request.scope == .repository(fullName: "octo/ghast"))
        #expect(request.name == "Mac-VM-a1b2c3")
        #expect(request.runnerGroupID == 1)
        #expect(request.labels == ["Mac-VM", "self-hosted", "macOS", "ARM64"])
        #expect(request.workFolder == "_work")
    }
}
