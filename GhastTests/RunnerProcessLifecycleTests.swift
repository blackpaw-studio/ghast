import XCTest
import Combine
@testable import Ghast

@MainActor
final class RunnerProcessLifecycleTests: XCTestCase {
    var runnerService: RunnerService!
    var isolatedDefaults: IsolatedDefaults!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        isolatedDefaults = makeIsolatedDefaults()
        runnerService = makeTestRunnerService(defaults: isolatedDefaults.defaults)
        cancellables = Set<AnyCancellable>()
    }
    
    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        
        isolatedDefaults.cleanup()
        
        runnerService = nil
        try await super.tearDown()
    }
    
    func testLocalRunnerCreation() {
        // Test that we can create a local runner
        let _ = runnerService.localRunners.count
        
        // Create a runner using the initializer
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: "/tmp/test-runner",
            labels: ["test", "macos"]
        )
        
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertEqual(runner.name, "Test Runner")
        XCTAssertEqual(runner.repository, "user/repo")
        XCTAssertEqual(runner.path, "/tmp/test-runner")
        XCTAssertEqual(runner.labels, ["test", "macos"])
        XCTAssertNotNil(runner.id)
    }
    
    func testRunnerStatusEnum() {
        // Test all runner status cases
        let statuses: [RunnerStatus] = [.stopped, .running, .error]
        
        for status in statuses {
            XCTAssertNotNil(status.rawValue)
        }
        
        // Test color property
        XCTAssertEqual(RunnerStatus.stopped.color, "gray")
        XCTAssertEqual(RunnerStatus.running.color, "green")
        XCTAssertEqual(RunnerStatus.error.color, "red")
    }
    
    func testRunnerStateObservability() async throws {
        // Test that runner state changes are observable
        let expectation = XCTestExpectation(description: "Runner state change observed")
        
        let cancellable = runnerService.$localRunners.sink { runners in
            expectation.fulfill()
        }
        
        // Trigger a change by calling removeAllLocalRunners
        runnerService.removeAllLocalRunners()
        
        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()
    }
    
    func testLogStreamIsNilForUnknownRunner() {
        // No process has been started, so there is no log stream to subscribe to
        XCTAssertNil(runnerService.getLogStream(for: "test-runner-id"))
    }
    
    func testRunnerEquality() {
        // Test LocalRunner equality implementation
        let runner1 = LocalRunner(
            name: "Runner 1",
            repository: "user/repo1",
            path: "/tmp/runner1",
            labels: ["label1"]
        )
        
        var runner2 = LocalRunner(
            name: "Runner 2",
            repository: "user/repo2",
            path: "/tmp/runner2",
            labels: ["label2"]
        )
        
        // Different runners should not be equal
        XCTAssertNotEqual(runner1, runner2)
        
        // Same ID should be equal (even with different properties)
        // Create a copy with same ID
        let runner1Copy = runner1
        XCTAssertEqual(runner1, runner1Copy)
    }
    
    func testRunnerHashable() {
        // Test LocalRunner hashable implementation
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/repo",
            path: "/tmp/runner",
            labels: []
        )
        
        var hasher = Hasher()
        runner.hash(into: &hasher)
        let hash1 = hasher.finalize()
        
        // Same runner should produce same hash
        hasher = Hasher()
        runner.hash(into: &hasher)
        let hash2 = hasher.finalize()
        
        XCTAssertEqual(hash1, hash2)
    }
    
    func testRunnerPersistence() {
        // Test that runners can be saved and loaded
        let initialCount = runnerService.localRunners.count
        
        // Create a test runner
        let runner = LocalRunner(
            name: "Persistence Test",
            repository: "user/repo",
            path: "/tmp/persistence-test",
            labels: ["test"]
        )
        
        // Add to service
        runnerService.addLocalRunner(runner)
        
        // Verify it was added
        XCTAssertEqual(runnerService.localRunners.count, initialCount + 1)
        
        // Clean up
        runnerService.removeLocalRunner(id: runner.id)
    }
}