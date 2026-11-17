import Foundation

/// What restarting at launch needs from the runner service.
@MainActor
protocol RunnerStarting: AnyObject {
    var localRunners: [LocalRunner] { get }
    func startRunner(id: String) async throws
    /// Shows a runner that could not be launched as an error.
    func recordStartFailure(id: String)
}

extension RunnerService: RunnerStarting {}

/// Starts the runners that were running when Ghast last quit (or crashed).
@MainActor
enum RestartAtLaunch {
    static let spacing: Duration = .seconds(1)

    /// Starts each runner with `shouldBeRunning`, `spacing` apart. A runner that can't be
    /// launched shows as an error; the rest still start.
    static func run(isEnabled: Bool, starter: any RunnerStarting, sleeper: Sleeper) async {
        guard isEnabled else { return }
        let ids = starter.localRunners.filter(\.shouldBeRunning).map(\.id)
        for (index, id) in ids.enumerated() {
            if index > 0 { try? await sleeper(spacing) }
            do {
                try await starter.startRunner(id: id)
            } catch {
                starter.recordStartFailure(id: id)
            }
        }
    }
}
