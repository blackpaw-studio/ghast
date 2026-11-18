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

    /// Which runners a pass starts. Launch restarts host runners at once and VM runners once
    /// leftover VMs are cleaned up, so each is its own pass.
    enum Group {
        case all, host, virtualMachines

        func includes(_ runner: LocalRunner) -> Bool {
            switch (self, runner.backend) {
            case (.all, _), (.host, .host): true
            case (.virtualMachines, .tart): true
            default: false
            }
        }
    }

    /// Starts each runner with `shouldBeRunning`, `spacing` apart. Each runner is checked again
    /// just before its start, so one stopped (Stop All) or taken by a flow (`isBusy`) while the
    /// loop waits is left alone. A runner that can't be launched shows as an error; the rest
    /// still start.
    static func run(isEnabled: Bool, runners group: Group = .all, starter: any RunnerStarting, sleeper: Sleeper, isBusy: (String) -> Bool = { _ in false }) async {
        guard isEnabled else { return }
        func shouldStart(_ id: String) -> Bool {
            !isBusy(id) && starter.localRunners.contains { $0.id == id && $0.shouldBeRunning && group.includes($0) }
        }
        // Set by a start, cleared by the wait after it: one wait between two starts, however
        // many runners are skipped in between.
        var needsSpacing = false
        for id in starter.localRunners.filter({ $0.shouldBeRunning && group.includes($0) }).map(\.id) {
            guard shouldStart(id) else { continue }
            if needsSpacing {
                try? await sleeper(spacing)
                needsSpacing = false
                guard shouldStart(id) else { continue }
            }
            needsSpacing = true
            do {
                try await starter.startRunner(id: id)
            } catch {
                starter.recordStartFailure(id: id)
            }
        }
    }
}
