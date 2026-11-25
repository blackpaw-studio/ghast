import Foundation
import Testing
@testable import Ghast

@Suite("RecoveryPolicy")
struct RecoveryPolicyTests {
    private let policy = RecoveryPolicy.standard
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func exit(ranFor seconds: TimeInterval?) -> RunnerExit {
        RunnerExit(
            code: 1,
            startedAt: seconds.map { now.addingTimeInterval(-$0) },
            at: now,
            wasRequested: false
        )
    }

    @Test("Retries wait 5 s, then 30 s, then 2 min")
    func backoffSequence() {
        let delays = (0..<3).map { policy.decide(attemptsSoFar: $0, exit: exit(ranFor: 1)) }
        #expect(delays == [
            .retry(attempt: 1, after: .seconds(5)),
            .retry(attempt: 2, after: .seconds(30)),
            .retry(attempt: 3, after: .seconds(120)),
        ])
    }

    @Test("Gives up after the third failed retry")
    func givesUpAfterThree() {
        #expect(policy.decide(attemptsSoFar: 3, exit: exit(ranFor: 1)) == .giveUp(attempts: 3))
    }

    @Test("A run of 10 minutes or more restarts the count")
    func healthyRunResetsCount() {
        #expect(policy.decide(attemptsSoFar: 3, exit: exit(ranFor: 600)) == .retry(attempt: 1, after: .seconds(5)))
    }

    @Test("A run just under 10 minutes does not")
    func shortRunKeepsCount() {
        #expect(policy.decide(attemptsSoFar: 2, exit: exit(ranFor: 599)) == .retry(attempt: 3, after: .seconds(120)))
    }

    @Test("A failed start (no start time) continues the count")
    func failedStartContinuesCount() {
        #expect(policy.decide(attemptsSoFar: 1, exit: exit(ranFor: nil)) == .retry(attempt: 2, after: .seconds(30)))
    }
}
