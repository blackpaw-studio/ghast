#if DEBUG
import Foundation

/// The Jobs tab's design-kit rows for the main screen's VM runner: one of each result, so a
/// capture or snapshot shows every look. Times are relative to the fixture's "now".
enum FixtureJobHistory {
    private static let repository = "blackpaw-studio/ghast"

    /// Oldest first, the way the store keeps them.
    static func records(now: Date) -> [JobHistoryRecord] {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        func job(
            _ id: String, _ name: String, workflow: String, run: Int, result: JobHistoryResult,
            startedAgo: TimeInterval, lasted: TimeInterval?
        ) -> JobHistoryRecord {
            JobHistoryRecord(
                id: id, jobName: name, workflowName: workflow, repository: repository, runID: run, runAttempt: 1,
                result: result, startedAt: ago(startedAgo), finishedAt: lasted.map { ago(startedAgo).addingTimeInterval($0) },
                failureMessage: nil
            )
        }
        return [
            JobHistoryRecord(
                id: "5c0d1e", jobName: "deploy-docs", workflowName: "Docs", repository: repository, runID: 18_198, runAttempt: 1,
                result: .unknown, startedAt: ago(3 * 3600 + 20 * 60), finishedAt: nil, failureMessage: nil
            ),
            JobHistoryRecord(
                id: "7f3a90", jobName: nil, workflowName: nil, repository: nil, runID: nil, runAttempt: nil,
                result: .didNotStart, startedAt: ago(2 * 3600 + 5 * 60), finishedAt: ago(2 * 3600 + 4 * 60 + 30),
                failureMessage: "Error: Not enough disk space to pull macos-tahoe-xcode: needs about 141 GB, 98 GB free."
            ),
            job("b41e2d", "lint", workflow: "CI", run: 18_204, result: .cancelled, startedAgo: 100 * 60, lasted: 48),
            job("e9a6c7", "archive", workflow: "Release", run: 18_217, result: .failed, startedAgo: 52 * 60, lasted: 14 * 60 + 3),
            job("2d8f4b", "test (macOS)", workflow: "CI", run: 18_229, result: .succeeded, startedAgo: 18 * 60, lasted: 6 * 60 + 12),
            job("a1b2c3", "build", workflow: "CI", run: 18_231, result: .running, startedAgo: 180, lasted: nil),
        ]
    }
}
#endif
