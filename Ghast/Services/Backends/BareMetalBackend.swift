import Foundation

/// Runs runners as host processes: the `run.sh` wrapper in the runner's folder, supervised
/// through `Foundation.Process`. The lifecycle logic moved here from `RunnerService`
/// unchanged; only its reads and writes of the runner list go through `host`.
@MainActor
final class BareMetalBackend: RunnerBackend {
    weak var host: (any RunnerBackendHost)?

    private let clock: any AppClock
    private let launcher: any RunnerProcessLauncher
    private let restartDelay: Int
    private let sleeper: Sleeper
    private let signaling: any ProcessSignaling
    private let scanner: any RunnerProcessScanning

    /// A launched wrapper and the token that ties its termination callback to this launch.
    private struct RunningProcess {
        let handle: any RunnerProcessHandle
        let launchToken: UUID
        /// The wrapper leads its own process group, so the group is signalled as one.
        let processGroupID: pid_t
        /// Set once the wrapper has ended but its group has not: the runner is still shutting down.
        var exitCode: Int32?
    }

    private var runningProcesses: [String: RunningProcess] = [:]
    /// Runners Ghast has asked to stop; their next exit is a requested stop, not a crash.
    private var stopRequested: Set<String> = []
    /// Runners with a start in progress, including its wait for an old process to end.
    private var startsInFlight: Set<String> = []
    /// Pending starts a stop has cancelled; the start checks before it launches.
    private var cancelledStarts: Set<String> = []
    /// Callers of `stop` waiting for a runner's process to end.
    private var terminationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        clock: any AppClock,
        launcher: any RunnerProcessLauncher,
        restartDelay: Int,
        sleeper: @escaping Sleeper,
        signaling: any ProcessSignaling,
        scanner: any RunnerProcessScanning
    ) {
        self.clock = clock
        self.launcher = launcher
        self.restartDelay = restartDelay
        self.sleeper = sleeper
        self.signaling = signaling
        self.scanner = scanner
    }

    // MARK: - Starting

    /// Starts a runner. The runner reads as starting at once, even while the start waits for a
    /// pending stop or a leftover listener to end, and a second start for it is ignored until
    /// this one is done.
    func start(id: String) async throws {
        guard !startsInFlight.contains(id) else { return }
        guard let runner = host?.runner(id: id) else { throw RunnerError.runnerNotFound }
        startsInFlight.insert(id)
        cancelledStarts.remove(id)
        defer { startsInFlight.remove(id) }

        // Already running (and not stopping): nothing to show; the launch below reports it.
        if runningProcesses[id] == nil || stopRequested.contains(id) { host?.setProcessState(.starting, id: id) }
        do {
            try await launchRunner(id: id)
        } catch {
            settleAbandonedStart(id: id, lastExit: runner.lastExit)
            throw error
        }
        settleAbandonedStart(id: id, lastExit: runner.lastExit)
    }

    /// A start that ended without launching (it failed, or a stop cancelled it) must not leave
    /// the runner reading as starting.
    private func settleAbandonedStart(id: String, lastExit: RunnerExit?) {
        guard host?.processState(id: id) == .starting, runningProcesses[id] == nil, host?.runner(id: id) != nil else { return }
        host?.setProcessState(.restored(from: lastExit), id: id)
    }

    private func launchRunner(id: String) async throws {
        // A stop that is still pending (its card already reads stopped) must finish first.
        await waitForPendingStop(id: id)

        // A listener left by an earlier Ghast would hold the runner's GitHub session, and a second
        // copy would fight it ("A session for this runner already exists"). End it first. Done
        // before the lookups below, which must not span an await.
        if runningProcesses[id] == nil, let path = host?.runner(id: id)?.path {
            await stopLeftoverListeners(runnerID: id, path: path)
        }

        guard let runner = host?.runner(id: id) else {
            throw RunnerError.runnerNotFound
        }

        // Check if runner directory exists
        let runnerPath = URL(fileURLWithPath: runner.path)
        guard FileManager.default.fileExists(atPath: runnerPath.path) else {
            throw RunnerError.runnerDirectoryNotFound
        }

        // Check if already running
        if let existing = runningProcesses[id] {
            if existing.handle.isRunning {
                throw RunnerError.runnerAlreadyRunning
            }
            // Clean up the dead process reference
            runningProcesses.removeValue(forKey: id)
        }

        // A stop that came while this start waited cancels it.
        if cancelledStarts.remove(id) != nil { return }

        let script = RunnerWrapperScript.make(
            runnerPath: runner.path,
            logFile: logFile(for: runner).path,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            restartDelay: restartDelay
        )
        let spec = RunnerLaunchSpec(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", script],
            currentDirectory: runnerPath
        )

        let launchToken = UUID()
        stopRequested.remove(id)
        // The termination callback runs on a background queue; it only hops to the main actor.
        let handle = try launcher.launch(spec) { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.didTerminate(id: id, launchToken: launchToken, exitCode: exitCode)
            }
        }

        let pid = handle.processIdentifier
        let groupID = getpgid(pid)
        runningProcesses[id] = RunningProcess(handle: handle, launchToken: launchToken, processGroupID: groupID == -1 ? pid : groupID)
        host?.setProcessState(.running(since: clock.now()), id: id)

        host?.updateRunner(id: id) {
            $0.shouldBeRunning = true
            $0.status = .running
        }

        #if DEBUG
        print("🏃 Started runner '\(runner.name)' with PID: \(pid)")
        #endif
    }

    // MARK: - Termination

    /// Records how a launch ended. Ignores a callback from a launch that was already replaced.
    /// A wrapper that ends on a requested stop while its group lives on (SIGTERM ends the bash
    /// wrapper at once, but the listener is still deleting its GitHub session) is not the end:
    /// the stop watcher finishes it once the group is gone.
    private func didTerminate(id: String, launchToken: UUID, exitCode: Int32) {
        guard let running = runningProcesses[id], running.launchToken == launchToken else { return }
        if stopRequested.contains(id), signaling.isGroupAlive(running.processGroupID) {
            var ended = running
            ended.exitCode = exitCode
            runningProcesses[id] = ended
            return
        }
        completeTermination(id: id, exitCode: exitCode)
    }

    private func completeTermination(id: String, exitCode: Int32) {
        runningProcesses.removeValue(forKey: id)
        host?.recordExit(id: id, code: exitCode, wasRequested: stopRequested.remove(id) != nil)
        resumeTerminationWaiters(id: id)
    }

    private func resumeTerminationWaiters(id: String) {
        for waiter in terminationWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    // MARK: - Stopping

    /// How long a stopping runner gets to end on SIGTERM before SIGKILL. The listener ends its
    /// running job and deletes its GitHub session first; SIGKILL before that leaves a session
    /// behind, and the next start fails with "A session for this runner already exists".
    static let stopGracePeriod: Duration = .seconds(15)
    /// How long a listener gets, once its worker has been SIGKILLed, to delete its GitHub session
    /// before the whole group is SIGKILLed.
    static let listenerSignOutWindow: Duration = .seconds(5)
    /// How long SIGKILL gets before Ghast gives up waiting for the exit report.
    static let killWait: Duration = .seconds(1)
    /// How often a stopping runner's process group is checked for being gone.
    static let stopPollInterval: Duration = .milliseconds(100)

    /// Stops a runner and returns once its process group has ended, so a start right after
    /// succeeds. Bounded: SIGTERM, SIGKILL after `stopGracePeriod`, then Ghast records the stop
    /// itself after `killWait` if the exit is never reported.
    func stop(id: String) async {
        requestStop(id: id, keepingRunIntent: false)
        await waitForTermination(of: id)
    }

    /// Returns once the runner's current process has ended; immediately if there is none.
    private func waitForTermination(of id: String) async {
        guard runningProcesses[id] != nil else { return }
        await withCheckedContinuation { terminationWaiters[id, default: []].append($0) }
    }

    private func waitForPendingStop(id: String) async {
        guard stopRequested.contains(id) else { return }
        await waitForTermination(of: id)
    }

    /// Asks a runner to stop and returns immediately; the process ends (and is recorded) later.
    /// `keepingRunIntent` is for a quit: the runner stays marked to run, so the next launch
    /// starts it again.
    func requestStop(id: String, keepingRunIntent: Bool) {
        // A stop request ends the intent to keep running, even with no process to kill.
        if !keepingRunIntent, host?.runner(id: id)?.shouldBeRunning == true {
            host?.updateRunner(id: id) { $0.shouldBeRunning = false }
        }
        if startsInFlight.contains(id) { cancelledStarts.insert(id) }
        guard let running = runningProcesses[id] else {
            if startsInFlight.contains(id) { settleCancelledStart(id: id) }
            #if DEBUG
            print("🏃 No running process found for runner ID: \(id)")
            #endif
            return
        }
        // Already stopping: the escalation task from the first request is still running.
        guard stopRequested.insert(id).inserted else { return }
        if case let .running(since)? = host?.processState(id: id) { host?.setProcessState(.stopping(since: since), id: id) }
        host?.updateRunner(id: id) { $0.status = .stopped }

        // Graceful first. The wrapper leads its own process group, so the group signal reaches
        // the runner and its helpers and nothing else; no pattern kill, which would match
        // other runners whose folder name merely starts the same. SIGTERM is what Runner.Listener
        // answers by ending its job and deleting its GitHub session; `run.sh` forwards nothing,
        // so the signal has to reach the listener itself.
        send(SIGTERM, to: running)

        let launchToken = running.launchToken
        Task { [weak self] in await self?.escalateStop(id: id, launchToken: launchToken) }
    }

    /// A stop with no process to stop only cancels the pending start; the runner reads stopped.
    private func settleCancelledStart(id: String) {
        guard host?.processState(id: id) == .starting else { return }
        host?.setProcessState(.stopped, id: id)
    }

    /// Waits for the stop to finish. Past the grace period the job's worker is SIGKILLed first:
    /// the listener deletes its GitHub session only after the worker has exited (JobDispatcher
    /// `ShutdownAsync` awaits it), so a worker that is slow to cancel its job would otherwise
    /// cost the session. The listener then gets `listenerSignOutWindow`; only then the group.
    private func escalateStop(id: String, launchToken: UUID) async {
        if await waitForEnd(id: id, launchToken: launchToken, upTo: Self.stopGracePeriod) { return }
        await killWorkers(id: id, launchToken: launchToken)
        if await waitForEnd(id: id, launchToken: launchToken, upTo: Self.listenerSignOutWindow) { return }
        forceKill(id: id, launchToken: launchToken)
        if await waitForEnd(id: id, launchToken: launchToken, upTo: Self.killWait) { return }
        // The exit report never came after SIGKILL: record the stop here so callers aren't left waiting.
        if runningProcesses[id]?.launchToken == launchToken {
            completeTermination(id: id, exitCode: 128 + SIGKILL)
        }
    }

    /// SIGKILLs the `Runner.Worker` processes in the launch's group, leaving the listener to sign out.
    private func killWorkers(id: String, launchToken: UUID) async {
        guard let group = runningProcesses[id]?.processGroupID else { return }
        let processes = await scanner.scan()
        guard runningProcesses[id]?.launchToken == launchToken else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for pid in LeftoverListeners.workerPIDs(in: processes, inGroup: group, excluding: ownPID) {
            signaling.signal(SIGKILL, toProcess: pid)
        }
    }

    /// Polls until the launch has ended, wrapper and group both, or `limit` has passed.
    /// Returns whether it ended. Time is counted in sleeps, so a test's sleeper drives it.
    private func waitForEnd(id: String, launchToken: UUID, upTo limit: Duration) async -> Bool {
        var waited = Duration.zero
        while true {
            guard let running = runningProcesses[id], running.launchToken == launchToken else { return true }
            if let code = running.exitCode, !signaling.isGroupAlive(running.processGroupID) {
                completeTermination(id: id, exitCode: code)
                return true
            }
            guard waited < limit else { return false }
            try? await sleeper(Self.stopPollInterval)
            waited += Self.stopPollInterval
        }
    }

    /// Whether `kill(-pgid, …)` is safe: never Ghast's own group (that would signal Ghast itself),
    /// and never 0, 1 or negative values, which `kill` reads as "everything".
    nonisolated static func canSignalGroup(_ pgid: pid_t, ownGroup: pid_t = getpgrp()) -> Bool {
        SystemProcessSignaling.isSignalable(group: pgid, ownGroup: ownGroup)
    }

    /// Signals the process and, when that is safe, its whole group.
    private func send(_ signal: Int32, to running: RunningProcess) {
        if Self.canSignalGroup(running.processGroupID) {
            signaling.signal(signal, toGroup: running.processGroupID)
        }
        signaling.signal(signal, toProcess: running.handle.processIdentifier)
    }

    /// SIGKILLs the launch if any of it is still running.
    private func forceKill(id: String, launchToken: UUID) {
        guard let running = runningProcesses[id], running.launchToken == launchToken,
              running.handle.isRunning || signaling.isGroupAlive(running.processGroupID) else { return }
        send(SIGKILL, to: running)
    }

    /// Stops every runner for a quit and returns once they have ended, or after the same
    /// bounded grace period a single stop gets. Keeps `shouldBeRunning`, so the next launch can
    /// start them again.
    func stopAll() async {
        let ids = Array(runningProcesses.keys)
        for id in ids { requestStop(id: id, keepingRunIntent: true) }
        for id in ids { await waitForTermination(of: id) }
    }

    /// SIGKILLs whatever runner processes are still tracked, without waiting. The last step of a
    /// quit, for anything `stopAll` did not get to.
    func killRemaining() {
        for running in runningProcesses.values { send(SIGKILL, to: running) }
    }

    /// Ends listeners from an earlier Ghast that are still running from this runner's folder:
    /// SIGTERM so they delete their GitHub session, SIGKILL if they outlast the grace period.
    /// Only processes found in the runner's own folder are signalled.
    private func stopLeftoverListeners(runnerID: String, path: String) async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let found = LeftoverListeners.pids(in: await scanner.scan(), forRunnerAt: path, excluding: ownPID)
        // Ghast may have launched the runner while the scan ran; those listeners are its own.
        guard !found.isEmpty, runningProcesses[runnerID] == nil else { return }
        for pid in found { signaling.signal(SIGTERM, toProcess: pid) }

        var waited = Duration.zero
        while waited < Self.stopGracePeriod, found.contains(where: signaling.isProcessAlive) {
            try? await sleeper(Self.stopPollInterval)
            waited += Self.stopPollInterval
        }
        for pid in found where signaling.isProcessAlive(pid) {
            signaling.signal(SIGKILL, toProcess: pid)
        }
    }

    // MARK: - Liveness

    var hasActiveRunners: Bool { !runningProcesses.isEmpty }

    func isActive(id: String) -> Bool { runningProcesses[id] != nil }

    func isRunning(id: String) -> Bool { runningProcesses[id]?.handle.isRunning == true }

    func logFile(for runner: LocalRunner) -> URL {
        URL(fileURLWithPath: runner.path).appendingPathComponent(RunnerWrapperScript.logFileName)
    }
}
