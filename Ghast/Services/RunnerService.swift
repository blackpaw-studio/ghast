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
    @ObservationIgnored private let runsStrayProcessCleanup: Bool
    
    var localRunners: [LocalRunner] = []
    /// Runtime process state per runner id. A runner with no entry is stopped.
    private(set) var processStates: [String: RunnerProcessState] = [:]
    
    /// A launched wrapper and the token that ties its termination callback to this launch.
    private struct RunningProcess {
        let handle: any RunnerProcessHandle
        let launchToken: UUID
        /// The wrapper leads its own process group, so the group is signalled as one.
        let processGroupID: pid_t
    }
    
    @ObservationIgnored private var runningProcesses: [String: RunningProcess] = [:]
    /// Runners Ghast has asked to stop; their next exit is a requested stop, not a crash.
    @ObservationIgnored private var stopRequested: Set<String> = []
    /// Callers of `stopRunner` waiting for a runner's process to end.
    @ObservationIgnored private var terminationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    
    /// Base directory for all managed runners (the user's home directory, not sandboxed Application Support, in production)
    @ObservationIgnored private let runnersBaseDirectory: URL
    
    /// - Parameters:
    ///   - restartDelay: Seconds the wrapper waits before restarting a runner that updated itself.
    ///   - runsStrayProcessCleanup: Whether quitting also `pkill`s runner processes machine-wide.
    ///     Tests turn this off so they never touch the developer's real runners.
    init(
        defaults: UserDefaults = .standard,
        runnersDirectory: URL = RunnerService.defaultRunnersDirectory,
        clock: any AppClock = SystemClock(),
        launcher: any RunnerProcessLauncher = ProcessRunnerLauncher(),
        restartDelay: Int = RunnerWrapperScript.defaultRestartDelay,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        runsStrayProcessCleanup: Bool = true
    ) {
        self.store = RunnerStore(defaults: defaults)
        self.clock = clock
        self.launcher = launcher
        self.restartDelay = restartDelay
        self.sleeper = sleeper
        self.runsStrayProcessCleanup = runsStrayProcessCleanup
        self.runnersBaseDirectory = runnersDirectory
        createRunnersDirectoryIfNeeded()
        loadRunners()
        // Discover any existing runners not in our database
        discoverExistingRunners()
    }
    
    // MARK: - Automatic Runner Setup
    
    /// Automatically downloads, extracts, configures and creates a new runner
    func createManagedRunner(
        name: String,
        scope: RunnerScope,
        application: GitHubRunnerApplication,
        registrationToken: String,
        labels: [String] = []
    ) async throws -> LocalRunner {
        let runnerDir = runnersBaseDirectory.appendingPathComponent(name)
        
        // Create runner directory
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        
        // Download runner package
        let archiveURL = try await downloadRunnerPackage(from: application.downloadURL, to: runnerDir)
        
        // Extract archive
        try await extractRunnerPackage(archiveURL: archiveURL, to: runnerDir)
        
        // Configure runner
        try await configureRunner(
            at: runnerDir,
            scope: scope,
            token: registrationToken,
            name: name,
            labels: labels
        )
        
        // Create LocalRunner instance
        let runner = LocalRunner(
            name: name,
            scope: scope,
            path: runnerDir.path,
            labels: labels
        )
        
        // Add to managed runners
        addLocalRunner(runner)
        
        return runner
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
    
    private func downloadRunnerPackage(from urlString: String, to directory: URL) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw RunnerError.invalidDownloadURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        let archiveURL = directory.appendingPathComponent("actions-runner.tar.gz")
        try data.write(to: archiveURL)
        
        return archiveURL
    }
    
    private func extractRunnerPackage(archiveURL: URL, to directory: URL) async throws {
        let process = Process()
        process.currentDirectoryPath = directory.path
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", archiveURL.lastPathComponent]
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw RunnerError.extractionFailed
        }
        
        // Clean up archive file
        try FileManager.default.removeItem(at: archiveURL)
        
        // Clear quarantine on entire directory first
        try await clearQuarantineRecursively(for: directory)
        
        // Set executable permissions on all runner binaries
        try await setExecutablePermissions(in: directory)
    }
    
    private func setExecutablePermissions(in directory: URL) async throws {
        let fileManager = FileManager.default
        
        // List of known executable files in GitHub Actions runner
        let executableFiles = [
            "config.sh",
            "run.sh", 
            "env.sh",
            "bin/Runner.Listener",
            "bin/Runner.Worker",
            "bin/Runner.PluginHost",
            "externals/node16/bin/node",
            "externals/node20/bin/node"
        ]
        
        for executablePath in executableFiles {
            let fullPath = directory.appendingPathComponent(executablePath)
            if fileManager.fileExists(atPath: fullPath.path) {
                do {
                    // Set executable permissions
                    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fullPath.path)
                    
                    // Clear quarantine attribute to avoid Gatekeeper issues
                    try await clearQuarantineAttribute(for: fullPath)
                    
                    #if DEBUG
                    print("🏃 Set executable permissions for: \(executablePath)")
                    #endif
                } catch {
                    #if DEBUG
                    print("🏃 Warning: Failed to set permissions for \(executablePath): \(error)")
                    #endif
                }
            }
        }
        
        // Also find and set permissions for any other executable files in bin directory
        let binDirectory = directory.appendingPathComponent("bin")
        if fileManager.fileExists(atPath: binDirectory.path) {
            do {
                let binContents = try fileManager.contentsOfDirectory(at: binDirectory, includingPropertiesForKeys: nil)
                for binFile in binContents {
                    do {
                        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binFile.path)
                        try await clearQuarantineAttribute(for: binFile)
                    } catch {
                        // Silently continue if we can't set permissions on some files
                    }
                }
            } catch {
                #if DEBUG
                print("🏃 Warning: Could not scan bin directory: \(error)")
                #endif
            }
        }
    }
    
    private func clearQuarantineRecursively(for directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-rd", "com.apple.quarantine", directory.path]
        
        // Capture output to avoid showing expected errors
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            #if DEBUG
            print("🏃 Cleared quarantine attributes from runner directory")
            #endif
            // Don't throw on non-zero exit - files might not have quarantine attribute
        } catch {
            #if DEBUG
            print("🏃 Warning: Could not clear quarantine attributes: \(error)")
            #endif
        }
    }
    
    private func clearQuarantineAttribute(for fileURL: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", fileURL.path]
        
        // Capture output to avoid showing expected errors
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            // Don't throw on non-zero exit - file might not have quarantine attribute
        } catch {
            // Silently ignore errors - quarantine attribute might not exist
        }
    }
    
    /// Arguments for a non-interactive `config.sh` registering against `url`.
    static func configArguments(url: String, token: String, name: String, labels: [String]) -> [String] {
        let base = [
            "./config.sh",
            "--url", url,
            "--token", token,
            "--name", name,
            "--unattended",  // Non-interactive mode
        ]
        return labels.isEmpty ? base : base + ["--labels", labels.joined(separator: ",")]
    }

    private func configureRunner(
        at directory: URL,
        scope: RunnerScope,
        token: String,
        name: String,
        labels: [String]
    ) async throws {
        // Check if config.sh exists
        let configPath = directory.appendingPathComponent("config.sh")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            #if DEBUG
            print("🏃 Config script not found at: \(configPath.path)")
            #endif
            throw RunnerError.configurationFailed()
        }
        
        // Make config.sh executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configPath.path)
        
        let process = Process()
        process.currentDirectoryPath = directory.path
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        
        let arguments = Self.configArguments(url: scope.configURL, token: token, name: name, labels: labels)
        process.arguments = arguments
        
        // Capture output for debugging
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        #if DEBUG
        print("🏃 Running configuration command: \(arguments.joined(separator: " "))")
        print("🏃 Working directory: \(directory.path)")
        #endif
        
        try process.run()
        process.waitUntilExit()
        
        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        
        #if DEBUG
        print("🏃 Configuration output: \(output)")
        if !errorOutput.isEmpty {
            print("🏃 Configuration error: \(errorOutput)")
        }
        #endif
        
        if process.terminationStatus != 0 {
            #if DEBUG
            print("🏃 Configuration failed with exit code: \(process.terminationStatus)")
            #endif
            throw RunnerError.configurationFailed()
        }
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
    private func didTerminate(id: String, launchToken: UUID, exitCode: Int32) {
        guard runningProcesses[id]?.launchToken == launchToken else { return }
        runningProcesses.removeValue(forKey: id)
        recordExit(id: id, code: exitCode, wasRequested: stopRequested.remove(id) != nil)
        resumeTerminationWaiters(id: id)
    }
    
    private func resumeTerminationWaiters(id: String) {
        for waiter in terminationWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
    
    /// Updates state for a process that has ended. A requested stop leaves the runner `.stopped`;
    /// an unexpected exit leaves it `.exited` and clears the intent to keep running.
    private func recordExit(id: String, code: Int32, wasRequested: Bool) {
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
    }
    
    /// How long a stopping runner gets to exit on SIGTERM before SIGKILL, and then how long
    /// SIGKILL gets before Ghast gives up waiting for the exit report.
    static let stopGracePeriod: Duration = .seconds(1)
    
    /// Stops a runner and returns once its process has ended, so a start right after succeeds.
    /// Bounded: SIGTERM, then SIGKILL after the grace period, then Ghast records the stop itself
    /// after another grace period if the exit is never reported.
    func stopRunner(id: String) async {
        requestStop(id: id)
        guard runningProcesses[id] != nil else { return }
        await withCheckedContinuation { terminationWaiters[id, default: []].append($0) }
    }
    
    /// Asks a runner to stop and returns immediately; the process ends (and is recorded) later.
    private func requestStop(id: String) {
        // A stop request always ends the intent to keep running, even with no process to kill.
        if let index = localRunners.firstIndex(where: { $0.id == id }), localRunners[index].shouldBeRunning {
            localRunners[index].shouldBeRunning = false
            saveRunners()
        }
        guard let running = runningProcesses[id] else {
            #if DEBUG
            print("🏃 No running process found for runner ID: \(id)")
            #endif
            return
        }
        stopRequested.insert(id)
        if let index = localRunners.firstIndex(where: { $0.id == id }) {
            localRunners[index].status = .stopped
            saveRunners()
        }
        
        // Graceful first. The wrapper leads its own process group, so the group signal reaches
        // the runner and its helpers and nothing else; no pattern kill, which would match
        // other runners whose folder name merely starts the same.
        kill(-running.processGroupID, SIGTERM)
        
        let launchToken = running.launchToken
        Task { [weak self, sleeper] in
            try? await sleeper(Self.stopGracePeriod)
            guard let self, self.forceKill(id: id, launchToken: launchToken) else { return }
            try? await sleeper(Self.stopGracePeriod)
            self.giveUpWaiting(id: id, launchToken: launchToken)
        }
    }
    
    /// SIGKILLs the launch if it is still running. Returns whether it was.
    private func forceKill(id: String, launchToken: UUID) -> Bool {
        guard let running = runningProcesses[id], running.launchToken == launchToken, running.handle.isRunning else {
            return false
        }
        kill(-running.processGroupID, SIGKILL)
        kill(running.handle.processIdentifier, SIGKILL)
        return true
    }
    
    /// The exit report never came after SIGKILL: record the stop here so callers aren't left waiting.
    private func giveUpWaiting(id: String, launchToken: UUID) {
        didTerminate(id: id, launchToken: launchToken, exitCode: 128 + SIGKILL)
    }
    
    /// Stops every runner for a quit. A requested stop that keeps `shouldBeRunning`, so the next
    /// launch can start them again. Synchronous: it must finish before the app exits.
    func stopAllRunners() {
        #if DEBUG
        print("🏃 Stopping all running runners due to app termination...")
        #endif
        
        for (id, running) in Array(runningProcesses) {
            let pgid = running.processGroupID
            let pid = running.handle.processIdentifier
            
            // Graceful first: the process, then its whole group.
            running.handle.terminate()
            kill(-pgid, SIGTERM)
            
            let deadline = Date().addingTimeInterval(1.0)
            while running.handle.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            var code = 128 + SIGTERM
            if running.handle.isRunning {
                kill(-pgid, SIGKILL)
                kill(pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.1)
                code = 128 + SIGKILL
            }
            
            // The termination callback may never run (the app is exiting), so record it here.
            runningProcesses.removeValue(forKey: id)
            stopRequested.remove(id)
            recordExit(id: id, code: code, wasRequested: true)
            resumeTerminationWaiters(id: id)
        }
        
        if runsStrayProcessCleanup {
            comprehensiveRunnerCleanup()
        }
        
        #if DEBUG
        print("🏃 All runners stopped")
        #endif
    }
    
    private func comprehensiveRunnerCleanup() {
        #if DEBUG
        print("🏃 Starting fast runner process cleanup...")
        #endif
        
        // Fast cleanup script with minimal delays and no verbose output
        let cleanupScript = """
        #!/bin/bash
        
        # Fast kill all runner-related processes - no verbose output during app quit
        # Kill common GitHub Actions processes immediately
        pkill -f "Runner.Listener" 2>/dev/null || true
        pkill -f "run-helper.sh" 2>/dev/null || true
        pkill -f "./run.sh" 2>/dev/null || true
        pkill -f ".ghast/runners" 2>/dev/null || true
        
        # Brief pause for graceful termination
        sleep 0.5
        
        # Force kill any remaining processes
        pkill -9 -f "Runner.Listener" 2>/dev/null || true
        pkill -9 -f "run-helper.sh" 2>/dev/null || true
        pkill -9 -f "./run.sh" 2>/dev/null || true
        pkill -9 -f ".ghast/runners" 2>/dev/null || true
        
        exit 0
        """
        
        // Run cleanup asynchronously to avoid blocking app termination
        DispatchQueue.global(qos: .utility).async {
            let cleanupProcess = Process()
            cleanupProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            cleanupProcess.arguments = ["-c", cleanupScript]
            
            do {
                try cleanupProcess.run()
                // Don't wait for completion - let it run in background
                #if DEBUG
                print("🏃 Fast cleanup initiated")
                #endif
            } catch {
                #if DEBUG
                print("🏃 Warning: Could not run fast cleanup: \(error)")
                #endif
            }
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
