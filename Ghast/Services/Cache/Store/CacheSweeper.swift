import Foundation

/// Runs the cache sweep every `interval` until its task is cancelled.
struct CacheSweeper: Sendable {
    let sleeper: Sleeper
    let interval: Duration
    let sweep: @Sendable () async -> Void

    init(sleeper: @escaping Sleeper, interval: Duration, sweep: @escaping @Sendable () async -> Void) {
        self.sleeper = sleeper
        self.interval = interval
        self.sweep = sweep
    }

    /// Sleeps, then sweeps, until cancelled. A cancelled or failed sleep ends the loop.
    func run() async {
        while !Task.isCancelled {
            do {
                try await sleeper(interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await sweep()
        }
    }
}
