import Foundation
import Observation

/// Service for managing local GitHub Actions runners
@MainActor
@Observable
class RunnerService {
    static let defaultRunnersDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghast")
        .appendingPathComponent("runners")
    
    @ObservationIgnored private var store: RunnerStore
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let launcher: any RunnerProcessLauncher
    @ObservationIgnored private let restartDelay: Int
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let signaling: any ProcessSignaling
    @ObservationIgnored private let scanner: any RunnerProcessScanning
    
    var localRunners: [LocalRunner] = []
    /// Runtime process state per runner id. A runner with no entry is stopped.
    private(set) var processStates: [String: RunnerProcessState] = [:]
    
    /// A launched wrapper and the token that ties its termination callback to this launch.
    private struct RunningProcess {
        let handle: any RunnerProcessHandle
        let launchToken: UUID
        /// The wrapper leads its own process group, so the group is signalled as one.
        let processGroupID: pid_t
        /// Set once the wrapper has ended but its group has not: the runner is still shutting down.
        var exitCode: Int32?
    }
    
    @ObservationIgnored private var runningProcesses: [String: RunningProcess] = [:]
    /// Runners Ghast has asked to stop; their next exit is a requested stop, not a crash.
    @ObservationIgnored private var stopRequested: Set<String> = []
    /// Callers of `stopRunner` waiting for a runner's process to end.
    @ObservationIgnored private var terminationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Every runner process that ended, requested or not. One consumer.
    @ObservationIgnored let processExits: AsyncStream<RunnerProcessExit>
    @ObservationIgnored private let processExitSink: AsyncStream<RunnerProcessExit>.Continuation
    
    /// Base directory for all managed runners (the user's home directory, not sandboxed Application Support, in production)
    @ObservationIgnored private let runnersBaseDirectory: URL
    /// Where every managed runner keeps its folder.
    var runnersDirectory: URL { runnersBaseDirectory }
    
    /// - Parameters:
    ///   - restartDelay: Seconds the wrapper waits before restarting a runner that updated itself.
    ///   - signaling: How runner processes are signalled and probed.
    ///   - scanner: How leftover `Runner.Listener` processes from an earlier Ghast are found.
    init(
        defaults: UserDefaults = .standard,
        runnersDirectory: URL = RunnerService.defaultRunnersDirectory,
        clock: any AppClock = SystemClock(),
        launcher: any RunnerProcessLauncher = ProcessRunnerLauncher(),
        restartDelay: Int = RunnerWrapperScript.defaultRestartDelay,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        signaling: any ProcessSignaling = SystemProcessSignaling(),
        scanner: any RunnerProcessScanning = PSRunnerProcessScanner()
    ) {
        self.store = RunnerStore(defaults: defaults)
        self.clock = clock
        self.launcher = launcher
        self.restartDelay = restartDelay
        self.sleeper = sleeper
        self.signaling = signaling
        self.scanner = scanner
        self.runnersBaseDirectory = runnersDirectory
        (processExits, processExitSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        createRunnersDirectoryIfNeeded()
        loadRunners()
        // Discover any existing runners not in our database
        discoverExistingRunners()
    }
    
    private func createRunnersDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: runnersBaseDirectory, withIntermediateDirectories: true)
        } catch {
            #if DEBUG
            print("Failed to create runners directory: \(error)")
            #endif
        }
    }
    
    /// Arguments for a non-interactive `config.sh` registering against `url`.
    nonisolated static func configArguments(
        url: String,
        token: String,
        name: String,
        labels: [String],
        runnerGroup: String? = nil,
        workFolder: String = LocalRunner.defaultWorkFolder,
        replace: Bool = false
    ) -> [String] {
        let base = [
            "./config.sh",
            "--url", url,
            "--token", token,
            "--name", name,
            "--unattended",  // Non-interactive mode
            "--work", workFolder,
        ]
        let labelArguments = labels.isEmpty ? [] : ["--labels", labels.joined(separator: ",")]
        let groupArguments = runnerGroup.map { ["--runnergroup", $0] } ?? []
        return base + labelArguments + groupArguments + (replace ? ["--replace"] : [])
    }

    /// Arguments for `config.sh remove`, which unregisters the runner and deletes its local config.
    nonisolated static func removeArguments(token: String) -> [String] {
        ["./config.sh", "remove", "--token", token]
    }

    // MARK: - Local Runner Management
    
    func addLocalRunner(_ runner: LocalRunner) {
        localRunners.append(runner)
        processStates[runner.id] = .restored(from: runner.lastExit)
        saveRunners()
        
        // Sync environment files, pre-job and post-job scripts
        syncRunnerFiles(for: runner)
    }
    
    /// Manually scan for existing runners (can be called from UI)
    func scanForExistingRunners() {
        // Clean up "discovered" labels from existing runners
        for index in localRunners.indices {
            if localRunners[index].labels.contains("discovered") {
                localRunners[index].labels.removeAll { $0 == "discovered" }
            }
        }
        saveRunners()
        
        discoverExistingRunners()
    }
    
    func removeLocalRunner(id: String) {
        requestStop(id: id)
        localRunners.removeAll { $0.id == id }
        processStates.removeValue(forKey: id)
        saveRunners()
    }
    
    /// Removes all local runners and persists the empty state
    /// This is useful for testing or resetting the app state
    func removeAllLocalRunners() {
        // Stop all running runners first
        for runner in localRunners {
            requestStop(id: runner.id)
        }
        
        // Clear the array and persist the empty state
        localRunners.removeAll()
        processStates.removeAll()
        store.discardKeptRecords()
        saveRunners()
    }
    
    func startRunner(id: String) async throws {
        // A stop that is still pending (its card already reads stopped) must finish first.
        await waitForPendingStop(id: id)
        
        // A listener left by an earlier Ghast would hold the runner's GitHub session, and a second
        // copy would fight it ("A session for this runner already exists"). End it first. Done
        // before the lookups below, which must not span an await.
        if runningProcesses[id] == nil, let path = localRunners.first(where: { $0.id == id })?.path {
            await stopLeftoverListeners(runnerID: id, path: path)
        }
        
        guard let runnerIndex = localRunners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.runnerNotFound
        }
        
        let runner = localRunners[runnerIndex]
        
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
        
        let script = RunnerWrapperScript.make(
            runnerPath: runner.path,
            logFile: runnerPath.appendingPathComponent(RunnerWrapperScript.logFileName).path,
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
        processStates[id] = .running(since: clock.now())
        
        localRunners[runnerIndex].shouldBeRunning = true
        localRunners[runnerIndex].status = .running
        saveRunners()
        
        #if DEBUG
        print("🏃 Started runner '\(runner.name)' with PID: \(pid)")
        #endif
    }
    
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
        recordExit(id: id, code: exitCode, wasRequested: stopRequested.remove(id) != nil)
        resumeTerminationWaiters(id: id)
    }
    
    private func resumeTerminationWaiters(id: String) {
        for waiter in terminationWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
    
    /// Updates state for a process that has ended. A requested stop leaves the runner `.stopped`;
    /// an unexpected exit leaves it `.exited` and clears the intent to keep running.
    private func recordExit(id: String, code: Int32, wasRequested: Bool, announces: Bool = true) {
        guard let index = localRunners.firstIndex(where: { $0.id == id }) else {
            // The runner was removed while it stopped: nothing to record.
            processStates.removeValue(forKey: id)
            return
        }
        var startedAt: Date?
        if case let .running(since)? = processStates[id] { startedAt = since }
        let exit = RunnerExit(code: code, startedAt: startedAt, at: clock.now(), wasRequested: wasRequested)
        processStates[id] = wasRequested ? .stopped : .exited(exit)
        localRunners[index].lastExit = exit
        localRunners[index].status = .stopped
        if !wasRequested { localRunners[index].shouldBeRunning = false }
        saveRunners()
        if announces { processExitSink.yield(RunnerProcessExit(runnerID: id, exit: exit)) }
    }
    
    /// Shows a runner Ghast could not launch as an error, like an unexpected exit.
    func recordStartFailure(id: String) {
        guard runningProcesses[id] == nil else { return }
        // Not a process exit: the runner never ran, so nothing announces it.
        recordExit(id: id, code: RunnerExit.launchFailureCode, wasRequested: false, announces: false)
    }
    
    /// How long a stopping runner gets to end on SIGTERM before SIGKILL. The listener ends its
    /// running job and deletes its GitHub session first; SIGKILL before that leaves a session
    /// behind, and the next start fails with "A session for this runner already exists".
    static let stopGracePeriod: Duration = .seconds(15)
    /// How long SIGKILL gets before Ghast gives up waiting for the exit report.
    static let killWait: Duration = .seconds(1)
    /// How often a stopping runner's process group is checked for being gone.
    static let stopPollInterval: Duration = .milliseconds(100)
    
    /// Stops a runner and returns once its process group has ended, so a start right after
    /// succeeds. Bounded: SIGTERM, SIGKILL after `stopGracePeriod`, then Ghast records the stop
    /// itself after `killWait` if the exit is never reported.
    func stopRunner(id: String) async {
        requestStop(id: id)
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
    private func requestStop(id: String, keepingRunIntent: Bool = false) {
        // A stop request ends the intent to keep running, even with no process to kill.
        if !keepingRunIntent, let index = localRunners.firstIndex(where: { $0.id == id }), localRunners[index].shouldBeRunning {
            localRunners[index].shouldBeRunning = false
            saveRunners()
        }
        guard let running = runningProcesses[id] else {
            #if DEBUG
            print("🏃 No running process found for runner ID: \(id)")
            #endif
            return
        }
        // Already stopping: the escalation task from the first request is still running.
        guard stopRequested.insert(id).inserted else { return }
        if let index = localRunners.firstIndex(where: { $0.id == id }) {
            localRunners[index].status = .stopped
            saveRunners()
        }
        
        // Graceful first. The wrapper leads its own process group, so the group signal reaches
        // the runner and its helpers and nothing else; no pattern kill, which would match
        // other runners whose folder name merely starts the same. SIGTERM is what Runner.Listener
        // answers by ending its job and deleting its GitHub session; `run.sh` forwards nothing,
        // so the signal has to reach the listener itself.
        send(SIGTERM, to: running)
        
        let launchToken = running.launchToken
        Task { [weak self] in await self?.escalateStop(id: id, launchToken: launchToken) }
    }
    
    /// Waits for the stop to finish, SIGKILLing what outlasts the grace period.
    private func escalateStop(id: String, launchToken: UUID) async {
        if await waitForEnd(id: id, launchToken: launchToken, upTo: Self.stopGracePeriod) { return }
        forceKill(id: id, launchToken: launchToken)
        if await waitForEnd(id: id, launchToken: launchToken, upTo: Self.killWait) { return }
        // The exit report never came after SIGKILL: record the stop here so callers aren't left waiting.
        if runningProcesses[id]?.launchToken == launchToken {
            completeTermination(id: id, exitCode: 128 + SIGKILL)
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
    func stopAllRunners() async {
        let ids = Array(runningProcesses.keys)
        for id in ids { requestStop(id: id, keepingRunIntent: true) }
        for id in ids { await waitForTermination(of: id) }
    }
    
    /// SIGKILLs whatever runner processes are still tracked, without waiting. The last step of a
    /// quit, for anything `stopAllRunners` did not get to.
    func killRemainingRunners() {
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
    
    
    func getRunnerLogFile(for runnerId: String) -> URL? {
        guard let runner = localRunners.first(where: { $0.id == runnerId }) else { return nil }
        return URL(fileURLWithPath: runner.path).appendingPathComponent(RunnerWrapperScript.logFileName)
    }
    
    /// The runner's log text after the point the user last cleared (see `clearOutput`).
    func readRunnerLogs(for runnerId: String) -> String {
        let placeholder = "No logs available. Start the runner to see output."
        guard let runner = localRunners.first(where: { $0.id == runnerId }),
              let logFileURL = getRunnerLogFile(for: runnerId),
              FileManager.default.fileExists(atPath: logFileURL.path) else {
            return placeholder
        }
        
        do {
            let handle = try FileHandle(forReadingFrom: logFileURL)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: min(runner.outputClearOffset, size))
            let data = try handle.readToEnd() ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            return text.isEmpty ? placeholder : text
        } catch {
            return "Error reading log file: \(error.localizedDescription)"
        }
    }
    
    /// Hides everything logged so far from the Output tab. The file is never truncated, so the
    /// activity parser still sees every job (Jobs Today stays correct).
    func clearOutput(id: String) {
        guard let index = localRunners.firstIndex(where: { $0.id == id }),
              let logFileURL = getRunnerLogFile(for: id) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? UInt64) ?? nil
        localRunners[index].outputClearOffset = size ?? 0
        saveRunners()
    }
    
    func isRunnerRunning(id: String) -> Bool {
        return runningProcesses[id]?.handle.isRunning == true
    }
    
    /// Verify and sync runner status with actual process state
    func syncRunnerStatus(id: String) {
        guard let runnerIndex = localRunners.firstIndex(where: { $0.id == id }) else { return }
        
        let isActuallyRunning = runningProcesses[id]?.handle.isRunning == true
        let currentStatus = localRunners[runnerIndex].status
        
        // If status is out of sync, update it
        if currentStatus == .running && !isActuallyRunning {
            #if DEBUG
            print("🏃 Syncing runner status: \(localRunners[runnerIndex].name) is not actually running")
            #endif
            localRunners[runnerIndex].status = .stopped
            saveRunners()
        } else if currentStatus == .stopped && isActuallyRunning {
            #if DEBUG
            print("🏃 Syncing runner status: \(localRunners[runnerIndex].name) is actually running")
            #endif
            localRunners[runnerIndex].status = .running
            saveRunners()
        }
    }
    
    // MARK: - Persistence
    
    private func saveRunners() {
        do {
            try store.save(localRunners)
        } catch {
            #if DEBUG
            print("Failed to save runners: \(error)")
            #endif
        }
    }
    
    func loadRunners() {
        localRunners = store.load()
        
        // Reset all runners to stopped status on app startup since processes don't persist
        for index in localRunners.indices {
            if localRunners[index].status == .running {
                localRunners[index].status = .stopped
            }
        }
        processStates = Dictionary(uniqueKeysWithValues: localRunners.map { ($0.id, RunnerProcessState.restored(from: $0.lastExit)) })
        saveRunners()
        
        #if DEBUG
        print("🏃 Loaded \(localRunners.count) runners")
        #endif
    }
    
    /// A path with symlinks resolved, so `/var/…` and `/private/var/…` compare equal.
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    
    /// Discovers existing runners in the .ghast/runners directory that aren't tracked
    private func discoverExistingRunners() {
        #if DEBUG
        print("🏃 Scanning for existing runners in \(runnersBaseDirectory.path)")
        #endif
        
        guard FileManager.default.fileExists(atPath: runnersBaseDirectory.path) else {
            #if DEBUG
            print("🏃 Runners directory doesn't exist yet")
            #endif
            return
        }
        
        do {
            let runnerDirs = try FileManager.default.contentsOfDirectory(
                at: runnersBaseDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            
            for runnerDir in runnerDirs {
                // Check if it's a directory
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: runnerDir.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }
                
                // Check if runner is already tracked
                let runnerName = runnerDir.lastPathComponent
                let trackedPaths = Set(localRunners.map(\.path)).union(store.keptPaths).map(Self.canonicalPath)
                if trackedPaths.contains(Self.canonicalPath(runnerDir.path)) {
                    continue
                }
                
                // Check if it has runner files (run.sh and config.sh are good indicators)
                let runScript = runnerDir.appendingPathComponent("run.sh")
                let configScript = runnerDir.appendingPathComponent("config.sh")
                
                guard FileManager.default.fileExists(atPath: runScript.path) ||
                      FileManager.default.fileExists(atPath: configScript.path) else {
                    #if DEBUG
                    print("🏃 Skipping \(runnerName) - doesn't appear to be a runner directory")
                    #endif
                    continue
                }
                
                // Try to extract the scope from the .runner file if it exists:
                // https://github.com/{org} or https://github.com/{owner}/{repo}
                var scope = RunnerScope.repository(fullName: "Unknown/Repository")
                let runnerFile = runnerDir.appendingPathComponent(".runner")
                if FileManager.default.fileExists(atPath: runnerFile.path) {
                    do {
                        let data = try Data(contentsOf: runnerFile)
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let gitHubUrl = json["gitHubUrl"] as? String,
                           let parsed = RunnerScope(gitHubURL: gitHubUrl) {
                            scope = parsed
                        }
                    } catch {
                        #if DEBUG
                        print("🏃 Couldn't parse .runner file for \(runnerName)")
                        #endif
                    }
                }
                
                // Create a LocalRunner entry for this discovered runner
                let discoveredRunner = LocalRunner(
                    name: runnerName,
                    scope: scope,
                    path: runnerDir.path,
                    labels: ["self-hosted"]
                )
                
                #if DEBUG
                print("🏃 Discovered existing runner: \(runnerName) for \(scope.displayName)")
                #endif
                localRunners.append(discoveredRunner)
            }
            
            // Save if we discovered any new runners
            if !localRunners.isEmpty {
                saveRunners()
                #if DEBUG
                print("🏃 Total runners after discovery: \(localRunners.count)")
                #endif
            }
            
        } catch {
            #if DEBUG
            print("🏃 Error scanning runners directory: \(error)")
            #endif
        }
    }
    
    // MARK: - Environment and Scripts Management
    
    func updateRunnerEnvironmentVariables(id: String, environmentVariables: [String: String]) {
        guard let index = localRunners.firstIndex(where: { $0.id == id }) else { return }
        
        localRunners[index].environmentVariables = environmentVariables
        saveRunners()
        
        // Write .env file to runner directory
        writeEnvironmentFile(for: localRunners[index])
    }
    
    func updateRunnerPreJobScript(id: String, script: String?) {
        guard let index = localRunners.firstIndex(where: { $0.id == id }) else { return }
        
        localRunners[index].preJobScript = script
        saveRunners()
        
        // Write or remove pre-job script file
        writePreJobScript(for: localRunners[index])
    }
    
    func updateRunnerPostJobScript(id: String, script: String?) {
        guard let index = localRunners.firstIndex(where: { $0.id == id }) else { return }
        
        localRunners[index].postJobScript = script
        saveRunners()
        
        // Write or remove post-job script file
        writePostJobScript(for: localRunners[index])
    }
    
    private func writeEnvironmentFile(for runner: LocalRunner) {
        let envFilePath = "\(runner.path)/.env"
        
        if runner.environmentVariables.isEmpty {
            // Remove .env file if no environment variables
            try? FileManager.default.removeItem(atPath: envFilePath)
            return
        }
        
        var envContent = "# Environment variables for \(runner.name)\n"
        envContent += "# Managed by Ghast - do not edit manually\n\n"
        
        for (key, value) in runner.environmentVariables.sorted(by: { $0.key < $1.key }) {
            // Escape values that contain special characters
            let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
            envContent += "\(key)=\"\(escapedValue)\"\n"
        }
        
        do {
            try envContent.write(toFile: envFilePath, atomically: true, encoding: .utf8)
            #if DEBUG
            print("📝 Updated .env file for runner \(runner.name)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to write .env file for runner \(runner.name): \(error)")
            #endif
        }
    }
    
    private func writePreJobScript(for runner: LocalRunner) {
        let scriptPath = "\(runner.path)/pre-job.sh"
        
        guard let script = runner.preJobScript, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Remove script file if no script
            try? FileManager.default.removeItem(atPath: scriptPath)
            // Remove environment variable
            removeHookEnvironmentVariable(for: runner, hook: "ACTIONS_RUNNER_HOOK_JOB_STARTED")
            return
        }
        
        let scriptContent = """
        #!/bin/bash
        # Pre-job script for \(runner.name)
        # Managed by Ghast - do not edit manually
        
        \(script)
        """
        
        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            
            // Make script executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            
            // Set environment variable to point to script
            setHookEnvironmentVariable(for: runner, hook: "ACTIONS_RUNNER_HOOK_JOB_STARTED", scriptPath: scriptPath)
            
            #if DEBUG
            print("📝 Updated pre-job script for runner \(runner.name)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to write pre-job script for runner \(runner.name): \(error)")
            #endif
        }
    }
    
    private func writePostJobScript(for runner: LocalRunner) {
        let scriptPath = "\(runner.path)/post-job.sh"
        
        guard let script = runner.postJobScript, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Remove script file if no script
            try? FileManager.default.removeItem(atPath: scriptPath)
            // Remove environment variable
            removeHookEnvironmentVariable(for: runner, hook: "ACTIONS_RUNNER_HOOK_JOB_COMPLETED")
            return
        }
        
        let scriptContent = """
        #!/bin/bash
        # Post-job script for \(runner.name)
        # Managed by Ghast - do not edit manually
        
        \(script)
        """
        
        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            
            // Make script executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            
            // Set environment variable to point to script
            setHookEnvironmentVariable(for: runner, hook: "ACTIONS_RUNNER_HOOK_JOB_COMPLETED", scriptPath: scriptPath)
            
            #if DEBUG
            print("📝 Updated post-job script for runner \(runner.name)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to write post-job script for runner \(runner.name): \(error)")
            #endif
        }
    }
    
    private func setHookEnvironmentVariable(for runner: LocalRunner, hook: String, scriptPath: String) {
        let envFilePath = "\(runner.path)/.env"
        var currentEnvContent = ""
        
        // Read existing .env content
        if FileManager.default.fileExists(atPath: envFilePath) {
            currentEnvContent = (try? String(contentsOfFile: envFilePath, encoding: .utf8)) ?? ""
        }
        
        // Remove existing hook variable if present
        let lines = currentEnvContent.components(separatedBy: .newlines)
        let filteredLines = lines.filter { !$0.hasPrefix("\(hook)=") }
        
        // Add new hook variable
        var newContent = filteredLines.joined(separator: "\n")
        if !newContent.isEmpty && !newContent.hasSuffix("\n") {
            newContent += "\n"
        }
        newContent += "\(hook)=\"\(scriptPath)\"\n"
        
        do {
            try newContent.write(toFile: envFilePath, atomically: true, encoding: .utf8)
        } catch {
            #if DEBUG
            print("❌ Failed to update .env file with hook variable: \(error)")
            #endif
        }
    }
    
    private func removeHookEnvironmentVariable(for runner: LocalRunner, hook: String) {
        let envFilePath = "\(runner.path)/.env"
        
        guard FileManager.default.fileExists(atPath: envFilePath) else { return }
        
        let currentEnvContent = (try? String(contentsOfFile: envFilePath, encoding: .utf8)) ?? ""
        let lines = currentEnvContent.components(separatedBy: .newlines)
        let filteredLines = lines.filter { !$0.hasPrefix("\(hook)=") }
        
        let newContent = filteredLines.joined(separator: "\n")
        
        do {
            try newContent.write(toFile: envFilePath, atomically: true, encoding: .utf8)
        } catch {
            #if DEBUG
            print("❌ Failed to update .env file: \(error)")
            #endif
        }
    }
    
    // MARK: - Script and Environment File Synchronization
    
    func syncRunnerFiles(for runner: LocalRunner) {
        writeEnvironmentFile(for: runner)
        writePreJobScript(for: runner)
        writePostJobScript(for: runner)
    }
}
