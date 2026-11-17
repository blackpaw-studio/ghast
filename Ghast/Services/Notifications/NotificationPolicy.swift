import Foundation

/// A runner process that ended, as `RunnerService` recorded it.
struct RunnerProcessExit: Sendable, Equatable {
    let runnerID: String
    let exit: RunnerExit
}

/// Something that happened to a runner which might deserve a notification.
enum NotificationTrigger: Sendable, Equatable {
    case processExited(RunnerProcessExit)
    case live(RunnerLiveEvent)
}

/// A notification Ghast posts.
struct RunnerNotice: Sendable, Equatable {
    enum Kind: String, Sendable {
        case unexpectedStop = "runner.unexpected-stop"
        case jobFailed = "runner.job-failed"
    }

    let kind: Kind
    let runnerID: String
    let title: String
    let body: String
}

/// Decides which runner events become notifications, and their words.
///
/// Only process exits announce a stop: `RunnerService` knows whether Ghast asked for it. A
/// logged `ghast: exit` marker never does, since the wrapper also writes one for each
/// self-update restart and for every requested stop.
enum NotificationPolicy {
    /// Exit codes with which the runner asks the wrapper to start it again (self-update).
    static let selfUpdateExitCodes: Set<Int32> = [0, 2]

    static func notice(
        for trigger: NotificationTrigger,
        runnerName: String,
        notifyUnexpectedStop: Bool,
        notifyJobFailure: Bool
    ) -> RunnerNotice? {
        switch trigger {
        case let .processExited(ended):
            guard notifyUnexpectedStop,
                  !ended.exit.wasRequested,
                  !selfUpdateExitCodes.contains(ended.exit.code) else { return nil }
            return RunnerNotice(
                kind: .unexpectedStop,
                runnerID: ended.runnerID,
                title: "\(runnerName) stopped unexpectedly",
                body: "The runner exited with code \(ended.exit.code). Click to see its output."
            )
        case let .live(.jobFinished(runnerID, job)):
            guard notifyJobFailure, job.result == .failed else { return nil }
            return RunnerNotice(
                kind: .jobFailed,
                runnerID: runnerID,
                title: "\(job.name) failed on \(runnerName)",
                body: "Click to see its output."
            )
        case .live(.exited):
            return nil
        }
    }
}
