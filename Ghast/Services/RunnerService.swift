import Foundation
import Combine

/// Service for managing local GitHub Actions runners
@MainActor
class RunnerService: ObservableObject {
    static let shared = RunnerService()
    
    @Published var localRunners: [LocalRunner] = []
    
    private var runningProcesses: [String: Process] = [:]
    private var processGroupIDs: [String: pid_t] = [:]
    private var logStreams: [String: PassthroughSubject<String, Never>] = [:]
    
    /// Base directory for all managed runners
    private var runnersBaseDirectory: URL {
        // Use user's home directory instead of sandboxed Application Support
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".ghast").appendingPathComponent("runners")
    }
    
    private init() {
        createRunnersDirectoryIfNeeded()
        loadRunners()
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
            print("Failed to create runners directory: \(error)")
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
                    
                    print("🏃 Set executable permissions for: \(executablePath)")
                } catch {
                    print("🏃 Warning: Failed to set permissions for \(executablePath): \(error)")
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
                print("🏃 Warning: Could not scan bin directory: \(error)")
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
            print("🏃 Cleared quarantine attributes from runner directory")
            // Don't throw on non-zero exit - files might not have quarantine attribute
        } catch {
            print("🏃 Warning: Could not clear quarantine attributes: \(error)")
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
            print("🏃 Config script not found at: \(configPath.path)")
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
        
        print("🏃 Running configuration command: \(arguments.joined(separator: " "))")
        print("🏃 Working directory: \(directory.path)")
        
        try process.run()
        process.waitUntilExit()
        
        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        
        print("🏃 Configuration output: \(output)")
        if !errorOutput.isEmpty {
            print("🏃 Configuration error: \(errorOutput)")
        }
        
        if process.terminationStatus != 0 {
            print("🏃 Configuration failed with exit code: \(process.terminationStatus)")
            throw RunnerError.configurationFailed()
        }
    }
    
    // MARK: - Local Runner Management
    
    func addLocalRunner(_ runner: LocalRunner) {
        localRunners.append(runner)
        saveRunners()
    }
    
    func removeLocalRunner(id: String) {
        stopRunner(id: id)
        localRunners.removeAll { $0.id == id }
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
                print("🏃 Cleaning up dead process reference for runner \(id)")
                runningProcesses.removeValue(forKey: id)
                processGroupIDs.removeValue(forKey: id)
                if let stream = logStreams[id] {
                    stream.send(completion: .finished)
                    logStreams.removeValue(forKey: id)
                }
            }
        }
        
        let process = Process()
        process.currentDirectoryPath = runner.path
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        
        // Create a wrapper script that monitors the parent process and kills itself if parent dies
        // This ensures the runner process doesn't outlive Ghast
        let parentPID = ProcessInfo.processInfo.processIdentifier
        let wrapperScript = """
        #!/bin/bash
        
        # Remove set -e to prevent early exit and add more debugging
        echo "🏃 WRAPPER START: Wrapper script starting for runner '\(runner.name)'"
        echo "🏃 TARGET DIR: \(runner.path)"
        echo "🏃 PARENT PID: \(parentPID)"
        echo "🏃 CURRENT DIR: $(pwd)"
        
        # Change to the runner directory
        cd "\(runner.path)" 2>&1 || {
            echo "❌ ERROR: Cannot change to directory \(runner.path)"
            exit 1
        }
        
        echo "🏃 CHANGED TO: $(pwd)"
        echo "🏃 LISTING DIRECTORY:"
        ls -la | head -10
        
        # Verify run.sh exists and is executable
        if [ ! -f "./run.sh" ]; then
            echo "❌ ERROR: ./run.sh not found"
            exit 127
        fi
        
        echo "🏃 FOUND RUN.SH:"
        ls -la ./run.sh
        
        if [ ! -x "./run.sh" ]; then
            echo "🔧 MAKING EXECUTABLE: ./run.sh"
            chmod +x ./run.sh
        fi
        
        echo "✅ READY: run.sh is executable"
        
        echo "🚀 STARTING: About to execute ./run.sh"
        
        # Test if we can execute the runner at all
        echo "🧪 TESTING: Quick test of runner executable"
        if timeout 2s ./run.sh --version 2>&1; then
            echo "✅ RUNNER VERSION: Command worked"
        else
            echo "⚠️ RUNNER VERSION: Command failed or timed out"
        fi
        
        echo "🔄 STARTING RUNNER LOOP"
        
        # Simple loop to keep runner running
        while true; do
            echo "🔄 LOOP START: $(date)"
            
            # Run the runner and capture its output
            echo "🏃 EXECUTING: ./run.sh"
            ./run.sh &
            RUNNER_PID=$!
            
            echo "🏃 RUNNER PID: $RUNNER_PID"
            
            # Wait for completion
            wait $RUNNER_PID
            EXIT_CODE=$?
            
            echo "🏁 RUNNER EXIT: Code $EXIT_CODE at $(date)"
            
            # Check if parent is still alive
            if ! kill -0 \(parentPID) 2>/dev/null; then
                echo "🛑 PARENT DEAD: Stopping runner loop"
                break
            fi
            
            echo "💤 SLEEPING: 5 seconds before restart"
            sleep 5
        done
        
        echo "🏁 WRAPPER END: Runner loop finished"
        """
        
        process.arguments = ["-c", wrapperScript]
        
        // Setup output pipes
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Create log stream
        let logSubject = PassthroughSubject<String, Never>()
        logStreams[id] = logSubject
        
        // Send initial log message
        logSubject.send("🏃 Starting runner '\(runner.name)' at \(runner.path)\n")
        
        // Monitor output with weak references to avoid crashes
        outputPipe.fileHandleForReading.readabilityHandler = { [weak logSubject] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    DispatchQueue.main.async {
                        logSubject?.send(output)
                    }
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak logSubject] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    DispatchQueue.main.async {
                        logSubject?.send("[STDERR] \(output)")
                    }
                }
            }
        }
        
        // Setup termination handler
        process.terminationHandler = { [weak self] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            print("🏃 Runner '\(runner.name)' terminated with exit code: \(exitCode)")
            
            // Immediately clear file handle readability handlers to prevent crashes
            // Use the stored pipe references instead of accessing the terminated process
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            // Log specific error messages for common exit codes
            let errorMessage: String
            switch exitCode {
            case 127:
                errorMessage = "❌ Error: Command not found (./run.sh missing or not executable)\n"
                print("❌ Error: ./run.sh not found or not executable in \(runner.path)")
            case 126:
                errorMessage = "❌ Error: Permission denied (./run.sh not executable)\n"
            case 1:
                errorMessage = "⚠️ Runner exited with error\n"
            case 0:
                errorMessage = "✅ Runner exited normally\n"
            default:
                errorMessage = "⚠️ Runner exited with code \(exitCode)\n"
            }
            
            // Schedule cleanup on main actor
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                
                // Send termination message to log stream
                strongSelf.logStreams[id]?.send("🏃 Runner process terminated (exit code: \(exitCode))\n")
                strongSelf.logStreams[id]?.send(errorMessage)
                
                // Remove from tracking - this prevents reuse of the Process instance
                strongSelf.runningProcesses.removeValue(forKey: id)
                strongSelf.processGroupIDs.removeValue(forKey: id)
                
                // Close log stream
                strongSelf.logStreams[id]?.send(completion: .finished)
                strongSelf.logStreams[id] = nil
                
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
            print("🏃 Runner '\(runner.name)' initial process group: \(pgid)")
        }
        
        localRunners[runnerIndex].status = .running
        saveRunners()
        
        // Send process started confirmation
        logSubject.send("🏃 Runner process started (PID: \(process.processIdentifier))\n")
        print("🏃 Started runner '\(runner.name)' with PID: \(process.processIdentifier)")
    }
    
    func stopRunner(id: String) {
        guard let process = runningProcesses[id] else { 
            print("🏃 No running process found for runner ID: \(id)")
            return 
        }
        
        if let runner = localRunners.first(where: { $0.id == id }) {
            logStreams[id]?.send("🏃 Stopping runner '\(runner.name)'...\n")
            print("🏃 Stopping runner '\(runner.name)' (PID: \(process.processIdentifier))")
        }
        
        // Use stored process group ID if available, otherwise fall back to process PID
        let pgid = processGroupIDs[id] ?? process.processIdentifier
        
        print("🏃 Terminating process group \(pgid)")
        
        // First try graceful termination of the process group
        kill(-pgid, SIGTERM)
        
        // Also kill any related processes by pattern for this specific runner (async)
        if let runner = localRunners.first(where: { $0.id == id }) {
            let runnerPath = runner.path
            DispatchQueue.global(qos: .utility).async {
                let cleanupScript = """
                # Fast kill processes in this specific runner directory
                timeout 2s bash -c 'pkill -f "\(runnerPath)" 2>/dev/null || true' || true
                """
                
                let cleanupProcess = Process()
                cleanupProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
                cleanupProcess.arguments = ["-c", cleanupScript]
                
                do {
                    try cleanupProcess.run()
                    cleanupProcess.waitUntilExit()
                } catch {
                    print("🏃 Warning: Could not run runner-specific cleanup: \(error)")
                }
            }
        }
        
        // Give it a moment to terminate gracefully (reduced timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if process.isRunning {
                print("🏃 Force killing runner process group (PGID: \(pgid))")
                kill(-pgid, SIGKILL)
                kill(process.processIdentifier, SIGKILL)
                
                // Force kill any remaining processes for this runner (async)
                if let runner = self.localRunners.first(where: { $0.id == id }) {
                    let runnerPath = runner.path
                    DispatchQueue.global(qos: .utility).async {
                        let forceCleanupScript = """
                        # Fast force kill processes in this specific runner directory
                        timeout 1s bash -c 'pkill -9 -f "\(runnerPath)" 2>/dev/null || true' || true
                        """
                        
                        let forceCleanupProcess = Process()
                        forceCleanupProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
                        forceCleanupProcess.arguments = ["-c", forceCleanupScript]
                        
                        do {
                            try forceCleanupProcess.run()
                            forceCleanupProcess.waitUntilExit()
                        } catch {
                            print("🏃 Warning: Could not run force cleanup: \(error)")
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
        print("🏃 Stopping all running runners due to app termination...")
        
        // Create a list of processes to terminate to avoid modifying while iterating
        let processesToStop = Array(runningProcesses)
        
        for (id, process) in processesToStop {
            if let runner = localRunners.first(where: { $0.id == id }) {
                print("🏃 Terminating runner '\(runner.name)' (PID: \(process.processIdentifier))")
                logStreams[id]?.send("🏃 App terminating - stopping runner '\(runner.name)'...\n")
            }
            
            // Use stored process group ID if available, otherwise fall back to process PID
            let pgid = processGroupIDs[id] ?? process.processIdentifier
            let pid = process.processIdentifier
            
            print("🏃 Terminating process group \(pgid) for runner \(id)")
            
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
                print("🏃 Force killing runner process group (PGID: \(pgid))")
                
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
        
        // Close all log streams
        for (_, stream) in logStreams {
            stream.send(completion: .finished)
        }
        logStreams.removeAll()
        
        // Save updated runner states
        saveRunners()
        
        print("🏃 All runners stopped")
        
        // Comprehensive cleanup of all runner-related processes
        comprehensiveRunnerCleanup()
    }
    
    private func comprehensiveRunnerCleanup() {
        print("🏃 Starting fast runner process cleanup...")
        
        // Fast cleanup script with minimal delays and no verbose output
        let cleanupScript = """
        #!/bin/bash
        
        # Fast kill all runner-related processes - no verbose output during app quit
        # Use timeout to prevent hanging
        timeout 3s bash -c '
        
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
        
        ' 2>/dev/null || true
        
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
                print("🏃 Fast cleanup initiated")
            } catch {
                print("🏃 Warning: Could not run fast cleanup: \(error)")
            }
        }
    }
    
    func getLogStream(for runnerId: String) -> AnyPublisher<String, Never>? {
        return logStreams[runnerId]?.eraseToAnyPublisher()
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
            print("🏃 Syncing runner status: \(localRunners[runnerIndex].name) is not actually running")
            localRunners[runnerIndex].status = .stopped
            saveRunners()
        } else if currentStatus == .stopped && isActuallyRunning {
            print("🏃 Syncing runner status: \(localRunners[runnerIndex].name) is actually running")
            localRunners[runnerIndex].status = .running
            saveRunners()
        }
    }
    
    // MARK: - Persistence
    
    private func saveRunners() {
        do {
            let data = try JSONEncoder().encode(localRunners)
            UserDefaults.standard.set(data, forKey: "localRunners")
        } catch {
            print("Failed to save runners: \(error)")
        }
    }
    
    func loadRunners() {
        guard let data = UserDefaults.standard.data(forKey: "localRunners") else { return }
        
        do {
            localRunners = try JSONDecoder().decode([LocalRunner].self, from: data)
            
            // Reset all runners to stopped status on app startup since processes don't persist
            for index in localRunners.indices {
                if localRunners[index].status == .running {
                    localRunners[index].status = .stopped
                }
            }
            saveRunners()
            
            print("🏃 Loaded \(localRunners.count) runners")
        } catch {
            print("Failed to load runners: \(error)")
        }
    }
}

// MARK: - Data Models

struct LocalRunner: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let repository: String
    let path: String
    let labels: [String]
    var status: RunnerStatus
    let createdAt: Date
    
    init(name: String, repository: String, path: String, labels: [String] = []) {
        self.id = UUID().uuidString
        self.name = name
        self.repository = repository
        self.path = path
        self.labels = labels
        self.status = .stopped
        self.createdAt = Date()
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