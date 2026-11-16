import Foundation

/// Runner counts summed across several scopes (repositories and organizations).
struct RunnerStats: Equatable, Sendable {
    var total = 0
    var online = 0
    var busy = 0

    /// Fetches each scope in turn and sums the counts. A scope whose fetch fails is
    /// skipped so it can't hide the others; cancellation stops the load and is rethrown.
    @MainActor
    static func load(
        scopes: [RunnerScope],
        fetch: @MainActor (RunnerScope) async throws -> [GitHubRunner]
    ) async throws -> RunnerStats {
        var stats = RunnerStats()
        for scope in scopes {
            do {
                let runners = try await fetch(scope)
                stats.total += runners.count
                stats.online += runners.filter(\.isOnline).count
                stats.busy += runners.filter(\.busy).count
            } catch where error.isCancellation {
                throw error
            } catch {
                continue
            }
        }
        return stats
    }
}
