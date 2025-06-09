import Foundation
import Combine

/// Service for managing local GitHub Actions runners
@MainActor
class RunnerService: ObservableObject {
    static let shared = RunnerService()
    
    @Published var localRunners: [LocalRunner] = []
    
    private var runningProcesses: [String: Process] = [:]
    private var logStreams: [String: PassthroughSubject<String, Never>] = [:]
    
    private init() {
        loadRunners()
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
        }
    }
}