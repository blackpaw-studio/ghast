import Foundation

/// What to do after a runner exited or failed to start.
enum RecoveryDecision: Sendable, Equatable {
    /// Start again after `after`; this is retry number `attempt` (1-based).
    case retry(attempt: Int, after: Duration)
    /// Stop retrying after `attempts` retries.
    case giveUp(attempts: Int)
}

/// The timings of automatic recovery, in one place so tests can inject their own.
struct RecoveryPolicy: Sendable, Equatable {
    var delays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]
    /// A run at least this long resets the attempt count.
    var healthyWindow: Duration = .seconds(600)

    var maxAttempts: Int { delays.count }

    static let standard = RecoveryPolicy()

    /// Decides after `exit`, given the retries already used. A run that lasted `healthyWindow`
    /// restarts the count; a failed start (no `startedAt`) never does.
    func decide(attemptsSoFar: Int, exit: RunnerExit) -> RecoveryDecision {
        let used = isHealthy(exit) ? 0 : attemptsSoFar
        guard used < maxAttempts else { return .giveUp(attempts: maxAttempts) }
        return .retry(attempt: used + 1, after: delays[used])
    }

    private func isHealthy(_ exit: RunnerExit) -> Bool {
        guard let startedAt = exit.startedAt else { return false }
        return Duration.seconds(exit.at.timeIntervalSince(startedAt)) >= healthyWindow
    }
}
