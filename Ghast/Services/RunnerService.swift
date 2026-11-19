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
    @ObservationIgnored private let bareMetal: BareMetalBackend
    @ObservationIgnored private let tart: TartBackend
    
    var localRunners: [LocalRunner] = []
    /// Runtime process state per runner id. A runner with no entry is stopped.
    private(set) var processStates: [String: RunnerProcessState] = [:]
    
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
    ///   - tartBackend: Runs VM runners; the default cannot find Tart, so a VM runner reads as an error.
    init(
        defaults: UserDefaults = .standard,
        runnersDirectory: URL = RunnerService.defaultRunnersDirectory,
        clock: any AppClock = SystemClock(),
        launcher: any RunnerProcessLauncher = ProcessRunnerLauncher(),
        restartDelay: Int = RunnerWrapperScript.defaultRestartDelay,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        signaling: any ProcessSignaling = SystemProcessSignaling(),
        scanner: any RunnerProcessScanning = PSRunnerProcessScanner(),
        tartBackend: TartBackend? = nil
    ) {
        self.store = RunnerStore(defaults: defaults)
        self.clock = clock
        self.bareMetal = BareMetalBackend(
            clock: clock,
            launcher: launcher,
            restartDelay: restartDelay,
            sleeper: sleeper,
            signaling: signaling,
            scanner: scanner
        )
        self.tart = tartBackend ?? TartBackend.unavailable(defaults: defaults, clock: clock, sleeper: sleeper)
        self.runnersBaseDirectory = runnersDirectory
        (processExits, processExitSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        bareMetal.host = self
        tart.host = self
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
        backend(for: id).requestStop(id: id, keepingRunIntent: false)
        localRunners.removeAll { $0.id == id }
        processStates.removeValue(forKey: id)
        saveRunners()
    }
    
    /// Removes all local runners and persists the empty state
    /// This is useful for testing or resetting the app state
    func removeAllLocalRunners() {
        // Stop all running runners first
        for runner in localRunners {
            backend(for: runner.id).requestStop(id: runner.id, keepingRunIntent: false)
        }
        
        // Clear the array and persist the empty state
        localRunners.removeAll()
        processStates.removeAll()
        store.discardKeptRecords()
        saveRunners()
    }
    
    /// Starts a runner. The runner reads as starting at once, even while the start waits for a
    /// pending stop or a leftover listener to end, and a second start for it is ignored until
    /// this one is done.
    func startRunner(id: String) async throws {
        try await backend(for: id).start(id: id)
    }
    
    /// Stops a runner and returns once its process group has ended, so a start right after
    /// succeeds. Bounded: SIGTERM, SIGKILL after `stopGracePeriod`, then Ghast records the stop
    /// itself after `killWait` if the exit is never reported.
    func stopRunner(id: String) async {
        await backend(for: id).stop(id: id)
    }
    
    /// The backend that runs this runner; the host backend for an id with no runner.
    private func backend(for id: String) -> any RunnerBackend {
        switch localRunners.first(where: { $0.id == id })?.backend {
        case .tart?: tart
        case .host?, nil: bareMetal
        }
    }
    
    private var backends: [any RunnerBackend] { [bareMetal, tart] }
    
    // Process-lifecycle timing lives with the backend that applies it.
    static var stopGracePeriod: Duration { BareMetalBackend.stopGracePeriod }
    static var listenerSignOutWindow: Duration { BareMetalBackend.listenerSignOutWindow }
    static var killWait: Duration { BareMetalBackend.killWait }
    static var stopPollInterval: Duration { BareMetalBackend.stopPollInterval }
    
    nonisolated static func canSignalGroup(_ pgid: pid_t, ownGroup: pid_t = getpgrp()) -> Bool {
        BareMetalBackend.canSignalGroup(pgid, ownGroup: ownGroup)
    }
    
    /// Shows a runner Ghast could not launch as an error, like an unexpected exit.
    func recordStartFailure(id: String) {
        guard !backend(for: id).isActive(id: id) else { return }
        // Not a process exit: the runner never ran, so nothing announces it.
        recordExit(id: id, code: RunnerExit.launchFailureCode, wasRequested: false, announces: false)
    }
    
    /// Updates state for a process that has ended. A requested stop leaves the runner `.stopped`;
    /// an unexpected exit leaves it `.exited` and clears the intent to keep running.
    private func recordExit(id: String, code: Int32, wasRequested: Bool, announces: Bool) {
        guard let index = localRunners.firstIndex(where: { $0.id == id }) else {
            // The runner was removed while it stopped: nothing to record.
            processStates.removeValue(forKey: id)
            return
        }
        var startedAt: Date?
        switch processStates[id] {
        case let .running(since)?, let .stopping(since)?: startedAt = since
        case let .onDemand(state)?: startedAt = state.since
        default: break
        }
        let exit = RunnerExit(code: code, startedAt: startedAt, at: clock.now(), wasRequested: wasRequested)
        // A start queued behind this stop keeps reading as starting.
        processStates[id] = wasRequested ? (processStates[id] == .starting ? .starting : .stopped) : .exited(exit)
        localRunners[index].lastExit = exit
        localRunners[index].status = .stopped
        if !wasRequested { localRunners[index].shouldBeRunning = false }
        saveRunners()
        if announces { processExitSink.yield(RunnerProcessExit(runnerID: id, exit: exit)) }
    }
    
    /// Stops every runner for a quit and returns once they have ended, or after the same
    /// bounded grace period a single stop gets. Keeps `shouldBeRunning`, so the next launch can
    /// start them again.
    func stopAllRunners() async {
        // Together, so a quit waits as long as the slower kind, not the sum.
        async let hostRunners: Void = bareMetal.stopAll()
        async let vmRunners: Void = tart.stopAll()
        _ = await (hostRunners, vmRunners)
    }
    
    /// Whether launch recovery has anything to look at: a VM runner exists, or a crash left a
    /// lease. Without either, recovery would only search for Tart to find nothing.
    var needsTartRecovery: Bool {
        localRunners.contains { if case .tart = $0.backend { true } else { false } } || tart.hasLeases
    }

    /// Deletes VM clones and runner registrations an earlier Ghast left behind. Once per
    /// launch, after sign-in has restored the GitHub token.
    func recoverTartLeftovers() async {
        await tart.recoverLeftovers()
    }
    
    /// SIGKILLs whatever runner processes are still tracked, without waiting. The last step of a
    /// quit, for anything `stopAllRunners` did not get to.
    func killRemainingRunners() {
        for backend in backends { backend.killRemaining() }
    }
    
    
    func getRunnerLogFile(for runnerId: String) -> URL? {
        guard let runner = localRunners.first(where: { $0.id == runnerId }) else { return nil }
        return backend(for: runnerId).logFile(for: runner)
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
    
    /// Whether any runner process is still tracked, including one that is stopping.
    var hasRunningProcesses: Bool { backends.contains { $0.hasActiveRunners } }
    
    func isRunnerRunning(id: String) -> Bool {
        backend(for: id).isRunning(id: id)
    }
    
    /// Verify and sync runner status with actual process state
    func syncRunnerStatus(id: String) {
        guard let runnerIndex = localRunners.firstIndex(where: { $0.id == id }) else { return }
        
        let isActuallyRunning = backend(for: id).isRunning(id: id)
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
    
    /// Saves a VM runner's labels, runner group and image. Nothing is re-registered: the slot
    /// reads them again for its next VM. A blank group means the default group. Ignored for a
    /// host runner, whose registration these would not change.
    func updateTartSettings(id: String, labels: [String], runnerGroup: String?, image: String) {
        guard case .tart? = runner(id: id)?.backend else { return }
        let group = runnerGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateRunner(id: id) {
            $0.labels = labels
            $0.runnerGroup = group?.isEmpty == false ? group : nil
            $0.backend = .tart(image: image)
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

extension RunnerService: RunnerBackendHost {
    func runner(id: String) -> LocalRunner? {
        localRunners.first { $0.id == id }
    }
    
    func updateRunner(id: String, _ change: (inout LocalRunner) -> Void) {
        guard let index = localRunners.firstIndex(where: { $0.id == id }) else { return }
        change(&localRunners[index])
        saveRunners()
    }
    
    func processState(id: String) -> RunnerProcessState? {
        processStates[id]
    }
    
    func setProcessState(_ state: RunnerProcessState?, id: String) {
        processStates[id] = state
    }
    
    func recordExit(id: String, code: Int32, wasRequested: Bool) {
        recordExit(id: id, code: code, wasRequested: wasRequested, announces: true)
    }
}
