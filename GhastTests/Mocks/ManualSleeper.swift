import Foundation
@testable import Ghast

/// A sleeper that only wakes when the test says so.
@MainActor
final class ManualSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [Duration] = []

    nonisolated var sleeper: Sleeper {
        let sleeper: Sleeper = { [self] duration in
            await self.sleep(duration)
        }
        return sleeper
    }

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Wakes every sleeper still waiting.
    func wakeAll() {
        let woken = waiting
        waiting.removeAll()
        woken.forEach { $0.resume() }
    }
}
