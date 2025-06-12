import XCTest
import Combine
@testable import Ghast

@MainActor
final class RunnerServiceTests: XCTestCase {
    
    var runnerService: RunnerService!
    var tempDirectory: URL!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        
        runnerService = RunnerService.shared
        cancellables = Set<AnyCancellable>()
        
        // Create a temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghast-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Clean up any existing runners to ensure clean state
        runnerService.removeAllLocalRunners()
    }
    
    override func tearDown() async throws {
        // Clean up test runners
        runnerService.removeAllLocalRunners()
        
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)
        
        cancellables.removeAll()
        
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testSingletonInstance() {
        let instance1 = RunnerService.shared
        let instance2 = RunnerService.shared
        XCTAssertTrue(instance1 === instance2, "RunnerService should be a singleton")
    }
    
    func testInitialState() {
        // After clearing in setUp, should have no runners
        XCTAssertEqual(runnerService.localRunners.count, 0)
    }
    
    // MARK: - Local Runner Management Tests
    
    func testAddLocalRunner() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        XCTAssertEqual(runnerService.localRunners.count, 1)
        XCTAssertEqual(runnerService.localRunners.first?.name, "Test Runner")
        XCTAssertEqual(runnerService.localRunners.first?.repository, "user/repo")
    }
    
    func testRemoveLocalRunner() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        XCTAssertEqual(runnerService.localRunners.count, 1)
        
        runnerService.removeLocalRunner(id: runner.id)
        XCTAssertEqual(runnerService.localRunners.count, 0)
    }
    
    func testRemoveAllLocalRunners() {
        // Add multiple runners
        for i in 1...3 {
            let runner = LocalRunner(
                name: "Runner \(i)",
                repository: "user/repo\(i)",
                path: tempDirectory.appendingPathComponent("runner\(i)").path
            )
            runnerService.addLocalRunner(runner)
        }
        
        XCTAssertEqual(runnerService.localRunners.count, 3)
        
        runnerService.removeAllLocalRunners()
        XCTAssertEqual(runnerService.localRunners.count, 0)
    }
    
    // MARK: - Runner Status Tests
    
    func testIsRunnerRunning() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        // Initially should not be running
        XCTAssertFalse(runnerService.isRunnerRunning(id: runner.id))
    }
    
    func testSyncRunnerStatus() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        // Initially stopped
        XCTAssertEqual(runnerService.localRunners.first?.status, .stopped)
        
        // Sync should maintain stopped status
        runnerService.syncRunnerStatus(id: runner.id)
        XCTAssertEqual(runnerService.localRunners.first?.status, .stopped)
    }
    
    // MARK: - Log Management Tests
    
    func testGetRunnerLogFile() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        let logFile = runnerService.getRunnerLogFile(for: runner.id)
        XCTAssertNotNil(logFile)
        XCTAssertEqual(logFile?.lastPathComponent, "ghast-runner.log")
        XCTAssertEqual(logFile?.deletingLastPathComponent().path, tempDirectory.path)
    }
    
    func testReadRunnerLogsNoFile() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        let logs = runnerService.readRunnerLogs(for: runner.id)
        XCTAssertEqual(logs, "No logs available. Start the runner to see output.")
    }
    
    func testReadRunnerLogsWithContent() throws {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        // Create a log file
        let logContent = "Test log entry 1\nTest log entry 2\n"
        let logFile = tempDirectory.appendingPathComponent("ghast-runner.log")
        try logContent.write(to: logFile, atomically: true, encoding: .utf8)
        
        let logs = runnerService.readRunnerLogs(for: runner.id)
        XCTAssertEqual(logs, logContent)
    }
    
    func testClearRunnerLogs() throws {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        // Create a log file with content
        let logContent = "Test log entry to be cleared\n"
        let logFile = tempDirectory.appendingPathComponent("ghast-runner.log")
        try logContent.write(to: logFile, atomically: true, encoding: .utf8)
        
        // Clear logs
        runnerService.clearRunnerLogs(for: runner.id)
        
        // Verify file still exists but is empty
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))
        let clearedContent = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertEqual(clearedContent, "")
    }
    
    // MARK: - Log Stream Tests
    
    func testGetLogStream() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        
        runnerService.addLocalRunner(runner)
        
        // Initially no log stream
        let stream1 = runnerService.getLogStream(for: runner.id)
        XCTAssertNil(stream1)
        
        // Note: Cannot fully test log streaming without starting a runner,
        // which requires actual runner files
    }
    
    // MARK: - Persistence Tests
    
    func testSaveAndLoadRunners() {
        // Add runners
        let runner1 = LocalRunner(
            name: "Runner 1",
            repository: "user/repo1",
            path: tempDirectory.appendingPathComponent("runner1").path,
            labels: ["test", "macos"]
        )
        
        let runner2 = LocalRunner(
            name: "Runner 2",
            repository: "user/repo2",
            path: tempDirectory.appendingPathComponent("runner2").path,
            labels: ["production"]
        )
        
        runnerService.addLocalRunner(runner1)
        runnerService.addLocalRunner(runner2)
        
        // Load runners (simulating app restart)
        runnerService.loadRunners()
        
        // Verify runners are persisted
        XCTAssertEqual(runnerService.localRunners.count, 2)
        
        let loadedRunner1 = runnerService.localRunners.first { $0.name == "Runner 1" }
        XCTAssertNotNil(loadedRunner1)
        XCTAssertEqual(loadedRunner1?.repository, "user/repo1")
        XCTAssertEqual(loadedRunner1?.labels, ["test", "macos"])
        
        let loadedRunner2 = runnerService.localRunners.first { $0.name == "Runner 2" }
        XCTAssertNotNil(loadedRunner2)
        XCTAssertEqual(loadedRunner2?.repository, "user/repo2")
        XCTAssertEqual(loadedRunner2?.labels, ["production"])
    }
    
    func testLoadRunnersResetsRunningStatus() {
        // Add a runner and simulate it was running
        var runner = LocalRunner(
            name: "Running Runner",
            repository: "user/repo",
            path: tempDirectory.path
        )
        runner.status = .running
        
        // Manually save to UserDefaults
        let data = try! JSONEncoder().encode([runner])
        UserDefaults.standard.set(data, forKey: "localRunners")
        
        // Load runners
        runnerService.loadRunners()
        
        // Verify status is reset to stopped
        XCTAssertEqual(runnerService.localRunners.first?.status, .stopped)
    }
    
    // MARK: - Runner Discovery Tests
    
    func testDiscoverExistingRunners() throws {
        // Skip this test as it depends on the actual file system location
        throw XCTSkip("Test depends on file system location - skipping")
    }
    
    // MARK: - Error Handling Tests
    
    func testStartRunnerNotFound() async {
        do {
            try await runnerService.startRunner(id: "non-existent-id")
            XCTFail("Should throw runnerNotFound error")
        } catch let error as RunnerError {
            switch error {
            case .runnerNotFound:
                break // Expected error
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testStartRunnerDirectoryNotFound() async throws {
        let runner = LocalRunner(
            name: "Missing Runner",
            repository: "user/repo",
            path: "/non/existent/path"
        )
        
        runnerService.addLocalRunner(runner)
        
        do {
            try await runnerService.startRunner(id: runner.id)
            XCTFail("Should throw runnerDirectoryNotFound error")
        } catch let error as RunnerError {
            switch error {
            case .runnerDirectoryNotFound:
                break // Expected error
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    // MARK: - Download and Extraction Tests
    
    func testInvalidDownloadURL() async {
        let repo = GitHubRepository(
            id: 1,
            name: "test",
            fullName: "user/test",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: nil, email: nil),
            htmlURL: ""
        )
        
        let app = GitHubRunnerApplication(
            os: "osx",
            architecture: "arm64",
            downloadURL: "not-a-valid-url",
            filename: "runner.tar.gz"
        )
        
        do {
            _ = try await runnerService.createManagedRunner(
                name: "Test",
                repository: repo,
                application: app,
                registrationToken: "token"
            )
            XCTFail("Should throw invalidDownloadURL error")
        } catch {
            // Expected error - invalid URL will fail
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - LocalRunner Model Tests
    
    func testLocalRunnerInitialization() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: "/path/to/runner",
            labels: ["self-hosted", "macos"]
        )
        
        XCTAssertNotNil(runner.id)
        XCTAssertEqual(runner.name, "Test Runner")
        XCTAssertEqual(runner.repository, "user/repo")
        XCTAssertEqual(runner.path, "/path/to/runner")
        XCTAssertEqual(runner.labels, ["self-hosted", "macos"])
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertNotNil(runner.createdAt)
        XCTAssertTrue(runner.environmentVariables.isEmpty)
        XCTAssertNil(runner.preJobScript)
        XCTAssertNil(runner.postJobScript)
    }
    
    func testLocalRunnerEquality() {
        let runner1 = LocalRunner(name: "Runner", repository: "repo", path: "/path")
        let runner2 = runner1 // Same instance, same ID
        let runner3 = LocalRunner(name: "Runner", repository: "repo", path: "/path") // Different ID
        
        XCTAssertEqual(runner1, runner2)
        XCTAssertNotEqual(runner1, runner3)
    }
    
    func testLocalRunnerHashable() {
        let runner1 = LocalRunner(name: "Runner1", repository: "repo", path: "/path1")
        let runner2 = LocalRunner(name: "Runner2", repository: "repo", path: "/path2")
        
        var runnerSet = Set<LocalRunner>()
        runnerSet.insert(runner1)
        runnerSet.insert(runner2)
        
        XCTAssertEqual(runnerSet.count, 2)
        XCTAssertTrue(runnerSet.contains(runner1))
        XCTAssertTrue(runnerSet.contains(runner2))
    }
    
    // MARK: - RunnerStatus Tests
    
    func testRunnerStatusDisplayName() {
        XCTAssertEqual(RunnerStatus.stopped.displayName, "Stopped")
        XCTAssertEqual(RunnerStatus.running.displayName, "Running")
        XCTAssertEqual(RunnerStatus.error.displayName, "Error")
    }
    
    func testRunnerStatusColor() {
        XCTAssertEqual(RunnerStatus.stopped.color, "gray")
        XCTAssertEqual(RunnerStatus.running.color, "green")
        XCTAssertEqual(RunnerStatus.error.color, "red")
    }
    
    func testRunnerStatusCodable() throws {
        let statuses: [RunnerStatus] = [.stopped, .running, .error]
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(statuses)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([RunnerStatus].self, from: data)
        
        XCTAssertEqual(decoded, statuses)
    }
    
    // MARK: - RunnerError Tests
    
    func testRunnerErrorDescriptions() {
        XCTAssertEqual(RunnerError.runnerNotFound.errorDescription, "Runner not found")
        XCTAssertEqual(RunnerError.runnerDirectoryNotFound.errorDescription, "Runner directory not found. Please ensure the runner is properly configured.")
        XCTAssertEqual(RunnerError.runnerAlreadyRunning.errorDescription, "Runner is already running")
        XCTAssertEqual(RunnerError.failedToStart.errorDescription, "Failed to start runner")
        XCTAssertEqual(RunnerError.invalidDownloadURL.errorDescription, "Invalid download URL for runner package")
        XCTAssertEqual(RunnerError.downloadFailed.errorDescription, "Failed to download runner package")
        XCTAssertEqual(RunnerError.extractionFailed.errorDescription, "Failed to extract runner package")
        XCTAssertEqual(RunnerError.configurationFailed().errorDescription, "Failed to configure runner. Check Console.app for detailed logs.")
        XCTAssertEqual(RunnerError.configurationFailed(details: "Missing token").errorDescription, "Failed to configure runner: Missing token")
    }
    
    func testRunnerErrorLocalizedError() {
        let error: LocalizedError = RunnerError.runnerNotFound
        XCTAssertEqual(error.errorDescription, "Runner not found")
    }
}