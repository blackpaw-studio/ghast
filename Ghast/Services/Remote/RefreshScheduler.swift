import Foundation

/// Decides when Ghast asks GitHub for runner lists. Pure: the caller passes the time.
///
/// - Launch and explicit refreshes (after a create or remove) run at once.
/// - Activating the main window refreshes at most every 15 s.
/// - While the window is visible, a poll runs every 60 s; never while hidden or occluded.
/// - Repeated failures back off 60 → 120 → 240 → 600 s; a success resets.
/// - A rate limit blocks every trigger until GitHub's reset time.
struct RefreshScheduler: Sendable, Equatable {
    enum Trigger: Sendable, CaseIterable {
        case launch
        case activation
        case poll
        /// After a create or remove: the user is waiting for the list to change.
        case explicit
    }

    static let activationInterval: TimeInterval = 15
    static let pollInterval: TimeInterval = 60
    static let backoff: [TimeInterval] = [60, 120, 240, 600]

    private(set) var lastStart: Date?
    private(set) var consecutiveFailures = 0
    private(set) var blockedUntil: Date?

    func shouldRefresh(_ trigger: Trigger, now: Date, isVisible: Bool) -> Bool {
        if let blockedUntil, now < blockedUntil { return false }
        switch trigger {
        case .launch, .explicit:
            return true
        case .activation:
            return elapsed(now) >= Self.activationInterval && elapsed(now) >= backoffInterval
        case .poll:
            return isVisible && elapsed(now) >= max(Self.pollInterval, backoffInterval)
        }
    }

    /// When the next poll is due, for sleeping until then.
    func nextPollDate() -> Date? {
        let due = lastStart.map { $0.addingTimeInterval(max(Self.pollInterval, backoffInterval)) }
        guard let blockedUntil else { return due }
        return max(due ?? blockedUntil, blockedUntil)
    }

    mutating func didStart(at now: Date) {
        lastStart = now
    }

    mutating func didSucceed() {
        consecutiveFailures = 0
    }

    /// - Parameter retryAt: GitHub's rate-limit reset, if the failure was a rate limit.
    mutating func didFail(retryAt: Date?) {
        consecutiveFailures += 1
        if let retryAt { blockedUntil = max(blockedUntil ?? retryAt, retryAt) }
    }

    // MARK: -

    private func elapsed(_ now: Date) -> TimeInterval {
        lastStart.map { now.timeIntervalSince($0) } ?? .infinity
    }

    private var backoffInterval: TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        return Self.backoff[min(consecutiveFailures, Self.backoff.count) - 1]
    }
}
