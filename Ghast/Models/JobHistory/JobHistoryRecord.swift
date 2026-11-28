import Foundation

enum JobHistoryResult: String, Codable, Sendable, Equatable {
    case succeeded, failed, cancelled, running, didNotStart, unknown
}

/// One job a VM runner ran, or tried to run, kept on disk by `JobHistory`.
struct JobHistoryRecord: Codable, Sendable, Equatable, Identifiable {
    /// The VM's 6-hex id.
    let id: String
    var jobName: String?
    var workflowName: String?
    /// `owner/repo`, validated against the runner's scope.
    var repository: String?
    var runID: Int?
    var runAttempt: Int?
    var result: JobHistoryResult
    let startedAt: Date
    var finishedAt: Date?
    /// Didn't-start rows only: the first error line the backend logged.
    var failureMessage: String?

    /// Built here from validated parts, never taken from the guest.
    var runURL: URL? {
        guard let repository, let runID, let runAttempt else { return nil }
        return URL(string: "https://github.com/\(repository)/actions/runs/\(runID)/attempts/\(runAttempt)")
    }
}
