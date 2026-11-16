import XCTest
@testable import Ghast

@MainActor
final class ConcurrentRunnerOperationsTests: XCTestCase {
    var runnerService: RunnerService!
    var isolatedDefaults: IsolatedDefaults!
    
    override func setUp() async throws {
        try await super.setUp()
        isolatedDefaults = makeIsolatedDefaults()
        runnerService = makeTestRunnerService(defaults: isolatedDefaults.defaults)
    }
    
    override func tearDown() async throws {
        isolatedDefaults.cleanup()
        
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
    
    func testLogFilesAreDistinctPerRunner() {
        let runners = (0..<5).map {
            LocalRunner(name: "Log Runner \($0)", repository: "user/repo", path: "/tmp/log-runner-\($0)")
        }
        runners.forEach { runnerService.addLocalRunner($0) }
        
        let logFiles = runners.compactMap { runnerService.getRunnerLogFile(for: $0.id) }
        
        XCTAssertEqual(Set(logFiles).count, runners.count)
        for (runner, logFile) in zip(runners, logFiles) {
            XCTAssertEqual(logFile.path, "\(runner.path)/ghast-runner.log")
        }
    }
    
    func testRunnersAppendedDirectlyAreVisible() {
        for i in 0..<3 {
            runnerService.localRunners.append(LocalRunner(
                name: "State Test Runner \(i)",
                repository: "user/repo",
                path: "/tmp/state-runner-\(i)",
                labels: []
            ))
        }
        
        XCTAssertEqual(runnerService.localRunners.count, 3)
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
                        // Add + remove (each persists via saveRunners)
                        let runner = LocalRunner(
                            name: "Safety Save \(i)",
                            repository: "user/repo",
                            path: "/tmp/safety-save-\(i)",
                            labels: []
                        )
                        self.runnerService.addLocalRunner(runner)
                        self.runnerService.removeLocalRunner(id: runner.id)
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