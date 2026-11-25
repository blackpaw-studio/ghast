import Foundation

/// Bookkeeping for automatic restarts: how many retries each runner has used, and the one
/// pending retry timer per runner. `RunnerService` owns it and decides what a retry does.
@MainActor
final class RunnerRecovery {
    /// What runs when a pending retry comes due.
    typealias Fire = @MainActor (String, RetryWait) async -> Void

    private struct Pending {
        let wait: RetryWait
        let task: Task<Void, Never>
        let fire: Fire
    }

    private let policy: RecoveryPolicy
    private let clock: any AppClock
    private let sleeper: Sleeper
    private var attempts: [String: Int] = [:]
    private var pending: [String: Pending] = [:]

    init(policy: RecoveryPolicy, clock: any AppClock, sleeper: @escaping Sleeper, power: any PowerEventSource) {
        self.policy = policy
        self.clock = clock
        self.sleeper = sleeper
        power.observe(willSleep: {}, didWake: { [weak self] in self?.fireDueWaits() })
    }

    /// Decides what follows `exit`, counting the retry it asks for.
    func decide(id: String, exit: RunnerExit) -> RecoveryDecision {
        let decision = policy.decide(attemptsSoFar: attempts[id] ?? 0, exit: exit)
        switch decision {
        case let .retry(attempt, _): attempts[id] = attempt
        case .giveUp: attempts[id] = nil
        }
        return decision
    }

    /// The wait that follows a `.retry` decision taken for `exit`.
    func wait(for exit: RunnerExit, attempt: Int, after delay: Duration) -> RetryWait {
        RetryWait(attempt: attempt, maxAttempts: policy.maxAttempts, dueAt: exit.at.addingTimeInterval(delay.seconds), lastExit: exit)
    }

    /// Runs `fire` after `delay`, unless the wait is cancelled or taken first. Replaces any
    /// wait the runner already had.
    func schedule(id: String, wait: RetryWait, after delay: Duration, fire: @escaping Fire) {
        pending[id]?.task.cancel()
        let sleeper = sleeper
        let task = Task { [weak self] in
            try? await sleeper(delay)
            guard !Task.isCancelled else { return }
            await self?.fireIfPending(id: id, wait: wait)
        }
        pending[id] = Pending(wait: wait, task: task, fire: fire)
    }

    /// Drops the runner's pending retry; the attempt count stays.
    func cancel(id: String) {
        pending.removeValue(forKey: id)?.task.cancel()
    }

    /// Drops every pending retry; the counts stay.
    func cancelAll() {
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
    }

    /// Forgets the runner's retries: a fresh start or an explicit stop.
    func resetAttempts(id: String) {
        attempts[id] = nil
    }

    /// Removes the runner's pending retry without running it and returns it.
    func takePending(id: String) -> RetryWait? {
        guard let taken = pending.removeValue(forKey: id) else { return nil }
        taken.task.cancel()
        return taken.wait
    }

    private func fireIfPending(id: String, wait: RetryWait) async {
        guard let current = pending[id], current.wait == wait else { return }
        pending[id] = nil
        await current.fire(id, wait)
    }

    /// After wake, retries whose time passed during sleep run at once.
    private func fireDueWaits() {
        let now = clock.now()
        for (id, entry) in pending where entry.wait.dueAt <= now {
            entry.task.cancel()
            pending[id] = nil
            Task { await entry.fire(id, entry.wait) }
        }
    }
}
