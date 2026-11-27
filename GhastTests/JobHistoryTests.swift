import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct JobHistoryTests {
    private let runner = "runner-1"
    private let clock = FakeClock()
    private let store = InMemoryJobHistoryStore()

    private func makeHistory(_ store: InMemoryJobHistoryStore? = nil) -> JobHistory {
        JobHistory(store: store ?? self.store, clock: clock)
    }

    private func vmID(_ number: Int) -> String { String(format: "%06x", number) }

    @Test("records come back newest first")
    func newestFirst() {
        let history = makeHistory()
        history.begin(runnerID: runner, vmID: "aaaaaa", at: clock.now())
        history.begin(runnerID: runner, vmID: "bbbbbb", at: clock.now().addingTimeInterval(5))
        #expect(history.records(for: runner).map(\.id) == ["bbbbbb", "aaaaaa"])
    }

    @Test("a runner keeps its newest 200 records")
    func cap() {
        let history = makeHistory()
        for number in 0...200 { history.begin(runnerID: runner, vmID: vmID(number), at: clock.now()) }
        let records = history.records(for: runner)
        #expect(records.count == 200)
        #expect(records.first?.id == vmID(200))
        #expect(records.last?.id == vmID(1))
        #expect(store.load(runnerID: runner).count == 200)
    }

    @Test("a record still Running at load becomes Unknown, with no finish time, and is saved")
    func runningBecomesUnknown() throws {
        let stale = JobHistoryRecord(
            id: "aaaaaa", jobName: "build", workflowName: nil, repository: nil, runID: nil, runAttempt: nil,
            result: .running, startedAt: clock.now(), finishedAt: nil, failureMessage: nil
        )
        let store = InMemoryJobHistoryStore([runner: [stale]])
        let history = makeHistory(store)

        let loaded = try #require(history.records(for: runner).first)
        #expect(loaded.result == .unknown)
        #expect(loaded.finishedAt == nil)
        #expect(store.load(runnerID: runner).first?.result == .unknown)
    }

    @Test("it writes when a record is created, when the run info arrives, and when it finishes")
    func writesAtEachStage() throws {
        let history = makeHistory()
        history.begin(runnerID: runner, vmID: "aaaaaa", at: clock.now())
        #expect(store.saveCount == 1)
        history.jobStarted(runnerID: runner, vmID: "aaaaaa", name: "build")
        history.runInfo(runnerID: runner, vmID: "aaaaaa", info: GuestRunInfo(repository: "acme/app", workflowName: "CI", runID: 9, runAttempt: 1))
        let writesBeforeFinish = store.saveCount
        clock.advance(by: 30)
        history.finish(runnerID: runner, vmID: "aaaaaa", result: .succeeded, at: clock.now())

        #expect(store.saveCount == writesBeforeFinish + 1)
        let saved = try #require(store.load(runnerID: runner).first)
        #expect(saved.jobName == "build")
        #expect(saved.repository == "acme/app")
        #expect(saved.runID == 9)
        #expect(saved.result == .succeeded)
        #expect(saved.finishedAt == clock.now())
    }

    @Test("a record finishes once")
    func finishOnce() throws {
        let history = makeHistory()
        history.begin(runnerID: runner, vmID: "aaaaaa", at: clock.now())
        history.finish(runnerID: runner, vmID: "aaaaaa", result: .failed, at: clock.now())
        let writes = store.saveCount
        clock.advance(by: 60)
        history.finish(runnerID: runner, vmID: "aaaaaa", result: .unknown, at: clock.now())

        let record = try #require(history.records(for: runner).first)
        #expect(record.result == .failed)
        #expect(record.finishedAt == clock.now().addingTimeInterval(-60))
        #expect(store.saveCount == writes)
    }

    @Test("run info with a missing field keeps what the record already has")
    func runInfoMerges() throws {
        let history = makeHistory()
        history.begin(runnerID: runner, vmID: "aaaaaa", at: clock.now())
        history.runInfo(runnerID: runner, vmID: "aaaaaa", info: GuestRunInfo(repository: nil, workflowName: "CI", runID: nil, runAttempt: nil))
        let record = try #require(history.records(for: runner).first)
        #expect(record.workflowName == "CI")
        #expect(record.runURL == nil)
    }

    @Test("a failure before the job starts turns the begun record into Didn't start, or makes one")
    func didNotStart() throws {
        let history = makeHistory()
        history.begin(runnerID: runner, vmID: "aaaaaa", at: clock.now())
        history.didNotStart(runnerID: runner, vmID: "aaaaaa", startedAt: clock.now(), message: "Error: clone failed")
        history.didNotStart(runnerID: runner, vmID: "bbbbbb", startedAt: clock.now(), message: "Error: pull failed")

        let records = history.records(for: runner)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.result == .didNotStart })
        #expect(Set(records.compactMap(\.failureMessage)) == ["Error: clone failed", "Error: pull failed"])
    }

    @Test("discard removes the record and writes")
    func discard() {
        let history = makeHistory()
        history.begin(runnerID: runner, vmID: "aaaaaa", at: clock.now())
        history.discard(runnerID: runner, vmID: "aaaaaa")
        #expect(history.records(for: runner).isEmpty)
        #expect(store.load(runnerID: runner).isEmpty)
    }

    @Test("after delete a VM that is still ending writes nothing")
    func deleteThenLateFinish() throws {
        let history = makeHistory()
        history.begin(runnerID: runner, vmID: "aaaaaa", at: clock.now())
        try history.delete(runnerID: runner)
        let writes = store.saveCount

        history.finish(runnerID: runner, vmID: "aaaaaa", result: .unknown, at: clock.now())
        history.begin(runnerID: runner, vmID: "bbbbbb", at: clock.now())

        #expect(store.saveCount == writes)
        #expect(store.load(runnerID: runner).isEmpty)
        #expect(history.records(for: runner).isEmpty)
    }
}
