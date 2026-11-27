import Testing
import Foundation
@testable import Ghast

@Suite struct JobHistoryRecordTests {
    private func record(repository: String? = "acme/app", runID: Int? = 42, runAttempt: Int? = 2) -> JobHistoryRecord {
        JobHistoryRecord(
            id: "a1b2c3", jobName: "build", workflowName: "CI", repository: repository,
            runID: runID, runAttempt: runAttempt, result: .succeeded,
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: nil, failureMessage: nil
        )
    }

    @Test("the run URL is built from the repository, run id and attempt")
    func runURL() {
        #expect(record().runURL?.absoluteString == "https://github.com/acme/app/actions/runs/42/attempts/2")
    }

    @Test("there is no run URL when any part is missing", arguments: [
        (nil as String?, 42 as Int?, 2 as Int?), ("acme/app", nil, 2), ("acme/app", 42, nil),
    ])
    func noRunURL(repository: String?, runID: Int?, attempt: Int?) {
        #expect(record(repository: repository, runID: runID, runAttempt: attempt).runURL == nil)
    }
}

@Suite struct GuestRunInfoTests {
    private let org = RunnerScope.organization(login: "Acme")
    private let repo = RunnerScope.repository(fullName: "Acme/App")

    private func raw(
        repository: String = "acme/app", workflow: String = "CI", runID: String = "7", attempt: String = "1"
    ) -> [String: String] {
        ["repository": repository, "workflow": workflow, "run_id": runID, "run_attempt": attempt]
    }

    @Test("good values pass; owner and repo compare without case")
    func good() {
        let info = GuestRunInfo.validated(raw(), scope: org)
        #expect(info == GuestRunInfo(repository: "acme/app", workflowName: "CI", runID: 7, runAttempt: 1))
        #expect(GuestRunInfo.validated(raw(repository: "ACME/APP"), scope: repo).repository == "ACME/APP")
    }

    @Test("a repository that fails the shape, or belongs to another owner, is dropped and the rest kept", arguments: [
        ("acme/app!", RunnerScope.organization(login: "Acme")),
        ("acme", RunnerScope.organization(login: "Acme")),
        ("acme/a/b", RunnerScope.organization(login: "Acme")),
        ("evil/app", RunnerScope.organization(login: "Acme")),
        ("acme/other", RunnerScope.repository(fullName: "Acme/App")),
        ("acme/app\n", RunnerScope.organization(login: "Acme")),
        ("a_b/app", RunnerScope.organization(login: "a_b")),
    ])
    func badRepository(repository: String, scope: RunnerScope) {
        let info = GuestRunInfo.validated(raw(repository: repository), scope: scope)
        #expect(info.repository == nil)
        #expect(info.workflowName == "CI")
        #expect(info.runID == 7)
    }

    @Test("run id and attempt must be positive integers", arguments: ["abc", "0", "-3", "", "1.5", "99999999999999999999"])
    func badNumbers(value: String) {
        let info = GuestRunInfo.validated(raw(runID: value, attempt: value), scope: org)
        #expect(info.runID == nil)
        #expect(info.runAttempt == nil)
        #expect(info.repository == "acme/app")
    }

    @Test("names are clipped to 200 characters and lose control characters")
    func names() {
        let long = String(repeating: "x", count: 300)
        #expect(GuestRunInfo.validated(raw(workflow: long), scope: org).workflowName?.count == 200)
        #expect(GuestRunInfo.validated(raw(workflow: "a\u{1B}[31mb\nc\u{0}d"), scope: org).workflowName == "a[31mbcd")
        #expect(GuestRunInfo.validated(raw(workflow: "\n\t"), scope: org).workflowName == nil)
        #expect(JobText.clean(long)?.count == 200)
    }

    @Test("the marker line decodes each base64 value")
    func marker() {
        let line = "ghast: run-info repository=\(b64("acme/app")) workflow=\(b64("CI")) run_id=\(b64("7")) run_attempt=\(b64("1"))"
        #expect(GuestRunInfo.parseMarker(line) == raw())
    }

    @Test("a marker with bad base64 or another prefix is not a marker")
    func badMarker() {
        #expect(GuestRunInfo.parseMarker("ghast: run-info repository=!!!") == nil)
        #expect(GuestRunInfo.parseMarker("Running job: build") == nil)
        #expect(GuestRunInfo.parseMarker("ghast: run-info workflow=\(b64("CI")) bogus") == ["workflow": "CI"])
    }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
}
