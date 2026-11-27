import Foundation

/// A runner process that ended, as `RunnerService` recorded it.
struct RunnerProcessExit: Sendable, Equatable {
    let runnerID: String
    let exit: RunnerExit
    /// Set when Ghast stopped retrying the runner after this many restart attempts.
    let gaveUpAfter: Int?
    /// Set when the runner stopped for a reason a retry can't fix.
    let blocked: RunnerExitBlock?

    init(runnerID: String, exit: RunnerExit, gaveUpAfter: Int? = nil, blocked: RunnerExitBlock? = nil) {
        self.runnerID = runnerID
        self.exit = exit
        self.gaveUpAfter = gaveUpAfter
        self.blocked = blocked
    }
}

/// Why a runner stopped without being retried: only the user can fix it.
enum RunnerExitBlock: Sendable, Equatable {
    /// The VM image won't fit in the free disk space.
    case insufficientDiskSpace(image: String)
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
            guard notifyUnexpectedStop, !ended.exit.wasRequested else { return nil }
            if case let .insufficientDiskSpace(image)? = ended.blocked {
                return RunnerNotice(
                    kind: .unexpectedStop,
                    runnerID: ended.runnerID,
                    title: "\(runnerName) can't pull \(TartImageRef.shortName(of: image)): not enough disk space",
                    body: "Free space in Settings › General › Tart Storage, then start it again. Click to see its output."
                )
            }
            if let attempts = ended.gaveUpAfter {
                // Ghast stopped retrying: the self-update exit codes don't apply, the runner stayed down.
                return RunnerNotice(
                    kind: .unexpectedStop,
                    runnerID: ended.runnerID,
                    title: "\(runnerName) stopped after \(attempts) restart attempts",
                    body: giveUpBody(for: ended.exit)
                )
            }
            guard !selfUpdateExitCodes.contains(ended.exit.code) else { return nil }
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

    private static func giveUpBody(for exit: RunnerExit) -> String {
        exit.code == RunnerExit.launchFailureCode
            ? "Ghast couldn't start it. Click to see its output."
            : "The runner exited with code \(exit.code). Click to see its output."
    }
}
