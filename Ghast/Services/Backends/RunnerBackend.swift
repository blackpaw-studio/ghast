import Foundation

/// What a backend needs from the service that owns the runner list: lookups, persisted
/// changes, and the runtime state the UI observes. `RunnerService` is the one implementation.
@MainActor
protocol RunnerBackendHost: AnyObject {
    func runner(id: String) -> LocalRunner?
    /// Applies `change` to the runner and persists the list; does nothing for an unknown id.
    func updateRunner(id: String, _ change: (inout LocalRunner) -> Void)
    func processState(id: String) -> RunnerProcessState?
    /// Sets a runner's runtime state; `nil` forgets it.
    func setProcessState(_ state: RunnerProcessState?, id: String)
    /// Records that a runner's process ended (see `RunnerService.recordExit`).
    func recordExit(id: String, code: Int32, wasRequested: Bool)
}

/// Where and how a runner's jobs execute. One instance serves every runner of its kind; it
/// owns that kind's process bookkeeping, `RunnerService` owns the list, persistence and
/// observable state.
@MainActor
protocol RunnerBackend: AnyObject {
    /// Starts the runner. Ignored while a start for it is already in progress.
    func start(id: String) async throws
    /// Asks the runner to stop and returns once it has ended.
    func stop(id: String) async
    /// Asks the runner to stop and returns at once. `keepingRunIntent` is for a quit: the
    /// runner stays marked to run, so the next launch starts it again.
    func requestStop(id: String, keepingRunIntent: Bool)
    /// Whether the runner's process is alive.
    func isRunning(id: String) -> Bool
    /// Whether anything of the runner is still tracked, including a stop in progress.
    func isActive(id: String) -> Bool
    /// Whether any runner of this kind is still tracked.
    var hasActiveRunners: Bool { get }
    /// Stops every runner of this kind for a quit; keeps `shouldBeRunning`.
    func stopAll() async
    /// SIGKILLs whatever is still tracked, without waiting. The last step of a quit.
    func killRemaining()
    func logFile(for runner: LocalRunner) -> URL
}
