import Foundation

/// The waits that decide which Mac holds a scale set's job queue (its one message session).
/// Injected so tests need no real time.
struct QueueTiming: Sendable {
    /// A primary retries a taken queue at this fixed pace.
    var primaryConflictRetry: Duration = .seconds(10)
    /// A standby's first retry of a taken queue; doubles with each consecutive one.
    var standbyConflictRetry: Duration = .seconds(5)
    var standbyConflictRetryMax: Duration = .seconds(60)
    /// A standby holding the queue gives it up after this long idle.
    var standbyYieldAfter: Duration = .seconds(5 * 60)
    /// After giving the queue up, a standby leaves it alone this long so a live primary takes it.
    var handoffWindow: Duration = .seconds(30)

    /// While holding the queue, jobs the service lists as acquirable are checked this often,
    /// so a message that never arrived (or arrived unreadable) cannot strand a job.
    var reconcileInterval: Duration = .seconds(2 * 60)

    static let standard = QueueTiming()

    /// The wait before retry number `streak` (0 for the first) of a queue another Mac holds.
    func conflictWait(role: QueueRole, streak: Int) -> Duration {
        switch role {
        case .primary:
            return primaryConflictRetry
        case .standby:
            // The cap keeps the shift far from overflowing; the max cap bites long before it.
            return min(standbyConflictRetry * (1 << min(streak, 16)), standbyConflictRetryMax)
        }
    }

    /// Whether a holder should give the queue up now: only a standby, only when it has been
    /// idle for the yield interval, counted from whichever is later, the start of the idle
    /// spell or the moment it took the queue (so it does not yield again as it takes it back).
    func shouldYield(role: QueueRole, idleSince: Date?, heldSince: Date, now: Date) -> Bool {
        guard role == .standby, let idleSince else { return false }
        return now.timeIntervalSince(max(idleSince, heldSince)) >= standbyYieldAfter.seconds
    }
}
