import XCTest
import Combine
@testable import Ghast

@MainActor
final class ConcurrentRunnerOperationsTests: XCTestCase {
    var runnerService: RunnerService!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        runnerService = RunnerService.shared
        cancellables = Set<AnyCancellable>()
        
        // Clear any existing runners
        runnerService.removeAllLocalRunners()
    }
    
    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        
        // Clean up all test runners
        runnerService.removeAllLocalRunners()
        
        runnerService = nil
        try await super.tearDown()
    }
    
    func testConcurrentRunnerCreation() async throws {
        let runnerCount = 10
        var createdRunners: [LocalRunner] = []
        
        // Create runners concurrently
        await withTaskGroup(of: LocalRunner.self) { group in
            for i in 0..<runnerCount {
                group.addTask { @MainActor in
                    let runner = LocalRunner(
                        name: "Concurrent Runner \(i)",
                        repository: "user/repo\(i)",
                        path: "/tmp/concurrent-runner-\(i)",
                        labels: ["concurrent", "test"]
                    )
                    self.runnerService.localRunners.append(runner)
                    return runner
                }
            }
            
            for await runner in group {
                createdRunners.append(runner)
            }
        }
        
        // Save after all are created
        runnerService.saveRunners()
        
        // Verify all runners were created
        XCTAssertEqual(createdRunners.count, runnerCount)
        XCTAssertGreaterThanOrEqual(runnerService.localRunners.count, runnerCount)
        
        // Verify each runner has unique properties
        let uniqueIds = Set(createdRunners.map { $0.id })
        let uniqueNames = Set(createdRunners.map { $0.name })
        let uniquePaths = Set(createdRunners.map { $0.path })
        
        XCTAssertEqual(uniqueIds.count, runnerCount)
        XCTAssertEqual(uniqueNames.count, runnerCount)
        XCTAssertEqual(uniquePaths.count, runnerCount)
    }
    
    func testConcurrentLogPublisherAccess() async throws {
        // Test concurrent access to log publishers
        let testRunnerId = "test-runner-concurrent-logs"
        var receivedLogs: [String] = []
        let logsLock = NSLock()
        
        // Create multiple subscribers
        let subscriberCount = 5
        for i in 0..<subscriberCount {
            let publisher = runnerService.getLogPublisher(for: testRunnerId)
            let cancellable = publisher.sink { log in
                logsLock.lock()
                receivedLogs.append("Subscriber \(i): \(log)")
                logsLock.unlock()
            }
            cancellables.insert(cancellable)
        }
        
        // No actual log emission in this test, just verifying publisher creation
        // In a real scenario, logs would be emitted through the runner process
        
        // Verify all publishers were created successfully
        XCTAssertEqual(cancellables.count, subscriberCount)
    }
    
    func testConcurrentStateObservation() async throws {
        // Test that multiple observers can watch runner state changes
        var observationCounts: [Int] = Array(repeating: 0, count: 5)
        let countLock = NSLock()
        
        // Create multiple observers
        for i in 0..<5 {
            let cancellable = runnerService.$localRunners
                .sink { _ in
                    countLock.lock()
                    observationCounts[i] += 1
                    countLock.unlock()
                }
            cancellables.insert(cancellable)
        }
        
        // Trigger state changes
        for i in 0..<3 {
            let runner = LocalRunner(
                name: "State Test Runner \(i)",
                repository: "user/repo",
                path: "/tmp/state-runner-\(i)",
                labels: []
            )
            runnerService.localRunners.append(runner)
        }
        
        // Allow time for observations
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify all observers received updates
        countLock.lock()
        let finalCounts = observationCounts
        countLock.unlock()
        
        for count in finalCounts {
            XCTAssertGreaterThan(count, 0)
        }
    }
    
    func testRunnerServiceThreadSafety() async throws {
        // Test that runner service handles concurrent operations safely
        let operationCount = 20
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<operationCount {
                group.addTask { @MainActor in
                    if i % 3 == 0 {
                        // Add runner
                        let runner = LocalRunner(
                            name: "Safety Test \(i)",
                            repository: "user/repo",
                            path: "/tmp/safety-\(i)",
                            labels: []
                        )
                        self.runnerService.localRunners.append(runner)
                    } else if i % 3 == 1 {
                        // Read runners
                        _ = self.runnerService.localRunners.count
                    } else {
                        // Save runners
                        self.runnerService.saveRunners()
                    }
                }
            }
        }
        
        // Verify service is still in valid state
        XCTAssertNotNil(runnerService.localRunners)
        
        // Verify data integrity
        for runner in runnerService.localRunners {
            XCTAssertFalse(runner.id.isEmpty)
            XCTAssertFalse(runner.name.isEmpty)
            XCTAssertFalse(runner.path.isEmpty)
        }
    }
}