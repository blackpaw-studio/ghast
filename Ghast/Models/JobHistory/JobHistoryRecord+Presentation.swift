import Foundation

extension JobHistoryResult {
    var title: String {
        switch self {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .running: "Running"
        case .didNotStart: "Didn't start"
        case .unknown: "Unknown"
        }
    }
}

/// What a Jobs row says. The words only; `JobsTabView` sets them.
extension JobHistoryRecord {
    /// The job's name, or a stand-in for a row that never got one.
    var displayName: String {
        if let jobName { return jobName }
        switch result {
        case .running: return "Starting job…"
        case .didNotStart: return "No job started"
        case .succeeded, .failed, .cancelled, .unknown: return "Unnamed job"
        }
    }

    /// `<workflow> · <owner/repo>` (whichever is known), or a Didn't-start row's error.
    var detailLine: String? {
        if result == .didNotStart { return failureMessage }
        let parts = [workflowName, repository].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How long the job ran: until it finished, or up to `now` while it runs. Nil when the end
    /// is unknown or no job ran.
    func duration(now: Date) -> TimeInterval? {
        switch result {
        case .running: now.timeIntervalSince(startedAt)
        case .succeeded, .failed, .cancelled: finishedAt.map { $0.timeIntervalSince(startedAt) }
        case .didNotStart, .unknown: nil
        }
    }
}
