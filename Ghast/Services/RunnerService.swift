import Foundation

/// Service for managing local GitHub Actions runners
@MainActor
class RunnerService: ObservableObject {
    static let defaultRunnersDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghast")
        .appendingPathComponent("runners")
    
    private let defaults: UserDefaults
    
    @Published var localRunners: [LocalRunner] = []
    
    private var runningProcesses: [String: Process] = [:]
    private var processGroupIDs: [String: pid_t] = [:]
    
    /// Base directory for all managed runners (the user's home directory, not sandboxed Application Support, in production)
    private let runnersBaseDirectory: URL
    
    init(defaults: UserDefaults = .standard, runnersDirectory: URL = RunnerService.defaultRunnersDirectory) {
        self.defaults = defaults
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
        repository: GitHubRepository,
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
            repository: repository,
            token: registrationToken,
            name: name,
            labels: labels
        )
        
        // Create LocalRunner instance
        let runner = LocalRunner(
            name: name,
            repository: repository.fullName,
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
    
    private func configureRunner(
        at directory: URL,
        repository: GitHubRepository,
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
        
        var arguments = [
            "./config.sh",
            "--url", repository.htmlURL,
            "--token", token,
            "--name", name,
            "--unattended"  // Non-interactive mode
        ]
        
        if !labels.isEmpty {
            arguments.append("--labels")
            arguments.append(labels.joined(separator: ","))
        }
        
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
        stopRunner(id: id)
        localRunners.removeAll { $0.id == id }
        saveRunners()
    }
    
    /// Removes all local runners and persists the empty state
    /// This is useful for testing or resetting the app state
    func removeAllLocalRunners() {
        // Stop all running runners first
        for runner in localRunners {
            stopRunner(id: runner.id)
        }
        
        // Clear the array and persist the empty state
        localRunners.removeAll()
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
        if let existingProcess = runningProcesses[id] {
            if existingProcess.isRunning {
                throw RunnerError.runnerAlreadyRunning
            } else {
                // Clean up dead process reference
                #if DEBUG
                print("🏃 Cleaning up dead process reference for runner \(id)")
                #endif
                runningProcesses.removeValue(forKey: id)
                processGroupIDs.removeValue(forKey: id)
            }
        }
        
        let process = Process()
        process.currentDirectoryPath = runner.path
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        
        // Create a wrapper script that monitors the parent process and kills itself if parent dies
        // This ensures the runner process doesn't outlive Ghast
        let parentPID = ProcessInfo.processInfo.processIdentifier
        let logFile = "\(runner.path)/ghast-runner.log"
        let wrapperScript = """
        #!/bin/bash
        
        # Set up log file
        LOG_FILE="\(logFile)"
        
        # Function to log with timestamp
        log_message() {
            echo "$(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE" >/dev/null
        }
        
        # Change to the runner directory
        cd "\(runner.path)" 2>&1 || {
            log_message "❌ ERROR: Cannot change to directory \(runner.path)"
            exit 1
        }
        
        # Verify run.sh exists and is executable
        if [ ! -f "./run.sh" ]; then
            log_message "❌ ERROR: ./run.sh not found"
            exit 127
        fi
        
        if [ ! -x "./run.sh" ]; then
            log_message "🔧 Making ./run.sh executable"
            chmod +x ./run.sh
        fi
        
        log_message "🏃 Starting runner '\(runner.name)'"
        
        # Simple loop to keep runner running
        while true; do
            # Run the runner and capture its output to log file
            log_message "🚀 Executing ./run.sh"
            # Run the runner and log output with timestamps
            ./run.sh > >(while IFS= read -r line; do echo "$(date '+%H:%M:%S') $line" >> "$LOG_FILE"; done) 2>&1 &
            RUNNER_PID=$!
            
            # Wait for completion
            wait $RUNNER_PID
            EXIT_CODE=$?
            
            log_message "🏁 Runner exited with code $EXIT_CODE"
            
            # Check if parent is still alive
            if ! kill -0 \(parentPID) 2>/dev/null; then
                log_message "🛑 Parent process terminated - stopping runner"
                break
            fi
            
            # Only restart if exit code suggests we should continue
            if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 2 ]; then
                log_message "🔄 Restarting runner in 5 seconds..."
                sleep 5
            else
                log_message "❌ Runner failed with exit code $EXIT_CODE - stopping"
                break
            fi
        done
        """
        
        process.arguments = ["-c", wrapperScript]
        
        // Setup output pipes
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Send initial log message to file
        let logFileURL = URL(fileURLWithPath: logFile)
        let initialMessage = "\(Date().formatted(date: .omitted, time: .standard)) 🏃 Starting runner '\(runner.name)' at \(runner.path)\n"
        
        // Append to existing log file or create new one
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                if let data = initialMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
        } else {
            try? initialMessage.write(to: logFileURL, atomically: false, encoding: .utf8)
        }
        
        // Setup termination handler
        process.terminationHandler = { [weak self] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            #if DEBUG
            print("🏃 Runner '\(runner.name)' terminated with exit code: \(exitCode)")
            #endif
            
            // Log termination to file
            let logFileURL = URL(fileURLWithPath: logFile)
            let terminationMessage = "\(Date().formatted(date: .omitted, time: .standard)) 🏃 Runner process terminated (exit code: \(exitCode))\n"
            
            // Append termination message
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                if let data = terminationMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
            
            // Log specific error messages for common exit codes
            let errorMessage: String
            switch exitCode {
            case 127:
                errorMessage = "❌ Error: Command not found (./run.sh missing or not executable)\n"
                #if DEBUG
                print("❌ Error: ./run.sh not found or not executable in \(runner.path)")
                #endif
            case 126:
                errorMessage = "❌ Error: Permission denied (./run.sh not executable)\n"
            case 1:
                errorMessage = "⚠️ Runner exited with error\n"
            case 0:
                errorMessage = "✅ Runner exited normally\n"
            default:
                errorMessage = "⚠️ Runner exited with code \(exitCode)\n"
            }
            
            // Write error message to log file
            let errorLogMessage = "\(Date().formatted(date: .omitted, time: .standard)) \(errorMessage)"
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                if let data = errorLogMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
            
            // Schedule cleanup on main actor
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                
                // Remove from tracking - this prevents reuse of the Process instance
                strongSelf.runningProcesses.removeValue(forKey: id)
                strongSelf.processGroupIDs.removeValue(forKey: id)
                
                if let index = strongSelf.localRunners.firstIndex(where: { $0.id == id }) {
                    strongSelf.localRunners[index].status = .stopped
                    strongSelf.saveRunners()
                }
            }
        }
        
        try process.run()
        
        // Store the PID and PGID immediately after launch
        let processPID = process.processIdentifier
        runningProcesses[id] = process
        
        // Store the process group ID (initially same as PID, will change with setsid)
        let pgid = getpgid(processPID)
        if pgid != -1 {
            processGroupIDs[id] = pgid
            #if DEBUG
            print("🏃 Runner '\(runner.name)' initial process group: \(pgid)")
            #endif
        }
        
        localRunners[runnerIndex].status = .running
        saveRunners()
        
        #if DEBUG
        print("🏃 Started runner '\(runner.name)' with PID: \(process.processIdentifier)")
        #endif
    }
    
    func stopRunner(id: String) {
        guard let process = runningProcesses[id] else { 
            #if DEBUG
            print("🏃 No running process found for runner ID: \(id)")
            #endif
            return 
        }
        
        #if DEBUG
        if let runner = localRunners.first(where: { $0.id == id }) {
            print("🏃 Stopping runner '\(runner.name)' (PID: \(process.processIdentifier))")
        }
        #endif
        
        // Use stored process group ID if available, otherwise fall back to process PID
        let pgid = processGroupIDs[id] ?? process.processIdentifier
        
        #if DEBUG
        print("🏃 Terminating process group \(pgid)")
        #endif
        
        // First try graceful termination of the process group
        kill(-pgid, SIGTERM)
        
        // Also kill any related processes by pattern for this specific runner (async)
        if let runner = localRunners.first(where: { $0.id == id }) {
            let runnerPath = runner.path
            DispatchQueue.global(qos: .utility).async {
                let cleanupScript = """
                # Fast kill processes in this specific runner directory
                pkill -f "\(runnerPath)" 2>/dev/null || true
                """
                
                let cleanupProcess = Process()
                cleanupProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
                cleanupProcess.arguments = ["-c", cleanupScript]
                
                do {
                    try cleanupProcess.run()
                    cleanupProcess.waitUntilExit()
                } catch {
                    #if DEBUG
                    print("🏃 Warning: Could not run runner-specific cleanup: \(error)")
                    #endif
                }
            }
        }
        
        // Give it a moment to terminate gracefully (reduced timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if process.isRunning {
                #if DEBUG
                print("🏃 Force killing runner process group (PGID: \(pgid))")
                #endif
                kill(-pgid, SIGKILL)
                kill(process.processIdentifier, SIGKILL)
                
                // Force kill any remaining processes for this runner (async)
                Task { @MainActor in
                    if let runner = self?.localRunners.first(where: { $0.id == id }) {
                        let runnerPath = runner.path
                        DispatchQueue.global(qos: .utility).async {
                            let forceCleanupScript = """
                            # Fast force kill processes in this specific runner directory
                            pkill -9 -f "\(runnerPath)" 2>/dev/null || true
                            """
                            
                            let forceCleanupProcess = Process()
                            forceCleanupProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
                            forceCleanupProcess.arguments = ["-c", forceCleanupScript]
                            
                            do {
                                try forceCleanupProcess.run()
                                forceCleanupProcess.waitUntilExit()
                            } catch {
                                #if DEBUG
                                print("🏃 Warning: Could not run force cleanup: \(error)")
                                #endif
                            }
                        }
                    }
                }
            }
        }
        
        if let runnerIndex = localRunners.firstIndex(where: { $0.id == id }) {
            localRunners[runnerIndex].status = .stopped
            saveRunners()
        }
    }
    
    func stopAllRunners() {
        #if DEBUG
        print("🏃 Stopping all running runners due to app termination...")
        #endif
        
        // Create a list of processes to terminate to avoid modifying while iterating
        let processesToStop = Array(runningProcesses)
        
        for (id, process) in processesToStop {
            #if DEBUG
            if let runner = localRunners.first(where: { $0.id == id }) {
                print("🏃 Terminating runner '\(runner.name)' (PID: \(process.processIdentifier))")
            }
            #endif
            
            // Use stored process group ID if available, otherwise fall back to process PID
            let pgid = processGroupIDs[id] ?? process.processIdentifier
            let pid = process.processIdentifier
            
            #if DEBUG
            print("🏃 Terminating process group \(pgid) for runner \(id)")
            #endif
            
            // First try to terminate the process normally
            process.terminate()
            
            // Send SIGTERM to the process group using stored PGID
            kill(-pgid, SIGTERM)
            
            // Give it a moment to terminate gracefully (reduced timeout for app termination)
            let deadline = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            // If still running, force kill the entire process group
            if process.isRunning {
                #if DEBUG
                print("🏃 Force killing runner process group (PGID: \(pgid))")
                #endif
                
                // Force terminate through Process API
                process.interrupt()
                
                // Send SIGKILL to process group
                kill(-pgid, SIGKILL)
                
                // Also kill the main process directly as backup
                kill(pid, SIGKILL)
                
                // Final wait
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            if let runnerIndex = localRunners.firstIndex(where: { $0.id == id }) {
                localRunners[runnerIndex].status = .stopped
            }
        }
        
        // Clear all running processes and process group IDs
        runningProcesses.removeAll()
        processGroupIDs.removeAll()
        
        // Save updated runner states
        saveRunners()
        
        #if DEBUG
        print("🏃 All runners stopped")
        #endif
        
        // Comprehensive cleanup of all runner-related processes
        comprehensiveRunnerCleanup()
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
        return URL(fileURLWithPath: runner.path).appendingPathComponent("ghast-runner.log")
    }
    
    func readRunnerLogs(for runnerId: String) -> String {
        guard let logFileURL = getRunnerLogFile(for: runnerId),
              FileManager.default.fileExists(atPath: logFileURL.path) else {
            return "No logs available. Start the runner to see output."
        }
        
        do {
            let logContent = try String(contentsOf: logFileURL, encoding: .utf8)
            return logContent.isEmpty ? "No logs available. Start the runner to see output." : logContent
        } catch {
            return "Error reading log file: \(error.localizedDescription)"
        }
    }
    
    func clearRunnerLogs(for runnerId: String) {
        guard let logFileURL = getRunnerLogFile(for: runnerId) else { return }
        
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                // Use FileHandle to truncate file while preserving file descriptor
                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                fileHandle.truncateFile(atOffset: 0)
                fileHandle.closeFile()
                #if DEBUG
                print("🏃 Cleared logs for runner \(runnerId)")
                #endif
            }
        } catch {
            #if DEBUG
            print("🏃 Warning: Could not clear log file: \(error)")
            #endif
        }
    }
    
    func isRunnerRunning(id: String) -> Bool {
        return runningProcesses[id]?.isRunning == true
    }
    
    /// Verify and sync runner status with actual process state
    func syncRunnerStatus(id: String) {
        guard let runnerIndex = localRunners.firstIndex(where: { $0.id == id }) else { return }
        
        let isActuallyRunning = runningProcesses[id]?.isRunning == true
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
            let data = try JSONEncoder().encode(localRunners)
            defaults.set(data, forKey: "localRunners")
        } catch {
            #if DEBUG
            print("Failed to save runners: \(error)")
            #endif
        }
    }
    
    func loadRunners() {
        guard let data = defaults.data(forKey: "localRunners") else { return }
        
        do {
            localRunners = try JSONDecoder().decode([LocalRunner].self, from: data)
            
            // Reset all runners to stopped status on app startup since processes don't persist
            for index in localRunners.indices {
                if localRunners[index].status == .running {
                    localRunners[index].status = .stopped
                }
            }
            saveRunners()
            
            #if DEBUG
            print("🏃 Loaded \(localRunners.count) runners")
            #endif
        } catch {
            #if DEBUG
            print("Failed to load runners: \(error)")
            #endif
        }
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
                if localRunners.contains(where: { $0.path == runnerDir.path }) {
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
                
                // Try to extract repository info from .runner file if it exists
                var repository = "Unknown/Repository"
                let runnerFile = runnerDir.appendingPathComponent(".runner")
                if FileManager.default.fileExists(atPath: runnerFile.path) {
                    do {
                        let data = try Data(contentsOf: runnerFile)
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let gitHubUrl = json["gitHubUrl"] as? String {
                            // Extract owner/repo from URL like https://github.com/owner/repo
                            if let url = URL(string: gitHubUrl),
                               url.pathComponents.count >= 3 {
                                repository = "\(url.pathComponents[1])/\(url.pathComponents[2])"
                            }
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
                    repository: repository,
                    path: runnerDir.path,
                    labels: ["self-hosted"]
                )
                
                #if DEBUG
                print("🏃 Discovered existing runner: \(runnerName) for \(repository)")
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
            currentEnvContent = (try? String(contentsOfFile: envFilePath)) ?? ""
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
        
        let currentEnvContent = (try? String(contentsOfFile: envFilePath)) ?? ""
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

// MARK: - Data Models

struct LocalRunner: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let repository: String
    let path: String
    var labels: [String]
    var status: RunnerStatus
    let createdAt: Date
    var environmentVariables: [String: String]
    var preJobScript: String?
    var postJobScript: String?
    
    init(name: String, repository: String, path: String, labels: [String] = []) {
        self.id = UUID().uuidString
        self.name = name
        self.repository = repository
        self.path = path
        self.labels = labels
        self.status = .stopped
        self.createdAt = Date()
        self.environmentVariables = [:]
        self.preJobScript = nil
        self.postJobScript = nil
    }
    
    // Custom equality based on ID only
    static func == (lhs: LocalRunner, rhs: LocalRunner) -> Bool {
        return lhs.id == rhs.id
    }
    
    // Custom hash based on ID only
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum RunnerStatus: String, Codable, CaseIterable {
    case stopped = "stopped"
    case running = "running"
    case error = "error"
    
    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .error: return "Error"
        }
    }
    
    var color: String {
        switch self {
        case .stopped: return "gray"
        case .running: return "green"
        case .error: return "red"
        }
    }
}

enum RunnerError: LocalizedError {
    case runnerNotFound
    case runnerDirectoryNotFound
    case runnerAlreadyRunning
    case failedToStart
    case invalidDownloadURL
    case downloadFailed
    case extractionFailed
    case configurationFailed(details: String? = nil)
    
    var errorDescription: String? {
        switch self {
        case .runnerNotFound:
            return "Runner not found"
        case .runnerDirectoryNotFound:
            return "Runner directory not found. Please ensure the runner is properly configured."
        case .runnerAlreadyRunning:
            return "Runner is already running"
        case .failedToStart:
            return "Failed to start runner"
        case .invalidDownloadURL:
            return "Invalid download URL for runner package"
        case .downloadFailed:
            return "Failed to download runner package"
        case .extractionFailed:
            return "Failed to extract runner package"
        case .configurationFailed(let details):
            if let details = details {
                return "Failed to configure runner: \(details)"
            } else {
                return "Failed to configure runner. Check Console.app for detailed logs."
            }
        }
    }
}