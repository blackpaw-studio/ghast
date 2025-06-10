import Foundation
import Combine

/// Service for managing local GitHub Actions runners
@MainActor
class RunnerService: ObservableObject {
    static let shared = RunnerService()
    
    @Published var localRunners: [LocalRunner] = []
    
    private var runningProcesses: [String: Process] = [:]
    private var logStreams: [String: PassthroughSubject<String, Never>] = [:]
    
    /// Base directory for all managed runners
    private var runnersBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Ghast").appendingPathComponent("Runners")
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
        if runningProcesses[id] != nil {
            throw RunnerError.runnerAlreadyRunning
        }
        
        let process = Process()
        process.currentDirectoryPath = runner.path
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["./run.sh"]
        
        // Setup output pipes
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Create log stream
        let logSubject = PassthroughSubject<String, Never>()
        logStreams[id] = logSubject
        
        // Monitor output
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                let output = String(data: data, encoding: .utf8) ?? ""
                Task { @MainActor in
                    logSubject.send(output)
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                let output = String(data: data, encoding: .utf8) ?? ""
                Task { @MainActor in
                    logSubject.send("ERROR: \(output)")
                }
            }
        }
        
        // Setup termination handler
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.runningProcesses[id] = nil
                self?.logStreams[id]?.send(completion: .finished)
                self?.logStreams[id] = nil
                
                if let index = self?.localRunners.firstIndex(where: { $0.id == id }) {
                    self?.localRunners[index].status = .stopped
                    self?.saveRunners()
                }
            }
        }
        
        try process.run()
        runningProcesses[id] = process
        localRunners[runnerIndex].status = .running
        saveRunners()
    }
    
    func stopRunner(id: String) {
        guard let process = runningProcesses[id] else { return }
        
        process.terminate()
        
        if let runnerIndex = localRunners.firstIndex(where: { $0.id == id }) {
            localRunners[runnerIndex].status = .stopped
            saveRunners()
        }
    }
    
    func getLogStream(for runnerId: String) -> AnyPublisher<String, Never>? {
        return logStreams[runnerId]?.eraseToAnyPublisher()
    }
    
    func isRunnerRunning(id: String) -> Bool {
        return runningProcesses[id]?.isRunning == true
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