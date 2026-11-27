import Testing
import Foundation
@testable import Ghast

@Suite struct JobHistoryPresentationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ result: JobHistoryResult, name: String? = "build", workflow: String? = "CI", repository: String? = "acme/app",
        finished: TimeInterval? = nil, failure: String? = nil
    ) -> JobHistoryRecord {
        JobHistoryRecord(
            id: "a1b2c3", jobName: name, workflowName: workflow, repository: repository, runID: 1, runAttempt: 1,
            result: result, startedAt: start, finishedAt: finished.map { start.addingTimeInterval($0) }, failureMessage: failure
        )
    }

    @Test("each result reads as words")
    func titles() {
        let titles = [JobHistoryResult.succeeded, .failed, .cancelled, .running, .didNotStart, .unknown].map(\.title)
        #expect(titles == ["Succeeded", "Failed", "Cancelled", "Running", "Didn't start", "Unknown"])
    }

    @Test("the detail line is workflow · repository, or what is known of it")
    func detailLine() {
        #expect(record(.succeeded).detailLine == "CI · acme/app")
        #expect(record(.succeeded, repository: nil).detailLine == "CI")
        #expect(record(.succeeded, workflow: nil).detailLine == "acme/app")
        #expect(record(.succeeded, workflow: nil, repository: nil).detailLine == nil)
    }

    @Test("a Didn't start row shows its error in place of the workflow")
    func didNotStartDetail() {
        #expect(record(.didNotStart, name: nil, workflow: nil, repository: nil, failure: "Error: clone failed").detailLine == "Error: clone failed")
    }

    @Test("a row with no job name still has a title")
    func displayName() {
        #expect(record(.succeeded).displayName == "build")
        #expect(record(.running, name: nil).displayName == "Starting job…")
        #expect(record(.didNotStart, name: nil).displayName == "No job started")
        #expect(record(.unknown, name: nil).displayName == "Unnamed job")
    }

    @Test("a finished job lasts until it finished, a running one counts up, the rest have none")
    func duration() {
        let now = start.addingTimeInterval(200)
        #expect(record(.succeeded, finished: 90).duration(now: now) == 90)
        #expect(record(.running).duration(now: now) == 200)
        #expect(record(.unknown).duration(now: now) == nil)
        #expect(record(.didNotStart, finished: 30).duration(now: now) == nil)
    }

    @Test("only a row with a run can be opened")
    func opens() {
        #expect(record(.succeeded).runURL != nil)
        #expect(record(.succeeded, repository: nil).runURL == nil)
    }
}
