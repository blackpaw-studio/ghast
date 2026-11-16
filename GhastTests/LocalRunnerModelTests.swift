import XCTest
import Foundation
@testable import Ghast

final class LocalRunnerModelTests: XCTestCase {
    
    func testLocalRunnerInitialization() {
        let runner = LocalRunner(
            name: "Test Runner",
            repository: "user/test-repo",
            path: "/Users/user/actions-runner",
            labels: ["self-hosted", "macOS"]
        )
        
        XCTAssertFalse(runner.id.isEmpty)
        XCTAssertEqual(runner.name, "Test Runner")
        XCTAssertEqual(runner.repository, "user/test-repo")
        XCTAssertEqual(runner.path, "/Users/user/actions-runner")
        XCTAssertEqual(runner.labels, ["self-hosted", "macOS"])
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertTrue(runner.environmentVariables.isEmpty)
        XCTAssertNil(runner.preJobScript)
        XCTAssertNil(runner.postJobScript)
        XCTAssertNotNil(runner.createdAt)
    }
    
    func testLocalRunnerInitializationWithDefaults() {
        let runner = LocalRunner(
            name: "Default Runner",
            repository: "user/default-repo",
            path: "/Users/user/runner"
        )
        
        XCTAssertTrue(runner.labels.isEmpty)
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertTrue(runner.environmentVariables.isEmpty)
        XCTAssertNil(runner.preJobScript)
        XCTAssertNil(runner.postJobScript)
    }
    
    func testLocalRunnerCodable() throws {
        var runner = LocalRunner(
            name: "Codable Test Runner",
            repository: "user/codable-repo",
            path: "/Users/user/codable-runner",
            labels: ["test", "codable"]
        )
        runner.environmentVariables = [
            "TEST_VAR": "test_value",
            "API_URL": "https://api.example.com"
        ]
        runner.preJobScript = "echo 'pre-job'"
        runner.postJobScript = "echo 'post-job'"
        runner.status = .running
        // The encoder derives the persisted `status` from run intent (see LocalRunnerMigrationTests).
        runner.shouldBeRunning = true
        
        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(runner)
        
        // Decode
        let decoder = JSONDecoder()
        let decodedRunner = try decoder.decode(LocalRunner.self, from: data)
        
        // Verify all properties are preserved
        XCTAssertEqual(decodedRunner.id, runner.id)
        XCTAssertEqual(decodedRunner.name, runner.name)
        XCTAssertEqual(decodedRunner.repository, runner.repository)
        XCTAssertEqual(decodedRunner.path, runner.path)
        XCTAssertEqual(decodedRunner.labels, runner.labels)
        XCTAssertEqual(decodedRunner.status, runner.status)
        XCTAssertEqual(decodedRunner.environmentVariables, runner.environmentVariables)
        XCTAssertEqual(decodedRunner.preJobScript, runner.preJobScript)
        XCTAssertEqual(decodedRunner.postJobScript, runner.postJobScript)
        XCTAssertEqual(decodedRunner.createdAt.timeIntervalSince1970, 
                      runner.createdAt.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func testLocalRunnerHashable() {
        let runner1 = LocalRunner(
            name: "Hash Test 1",
            repository: "user/hash-repo",
            path: "/Users/user/runner1"
        )
        
        let runner2 = LocalRunner(
            name: "Hash Test 2", 
            repository: "user/hash-repo",
            path: "/Users/user/runner2"
        )
        
        var runner3 = runner1
        runner3.status = .running
        
        // Can be used in Sets - this tests hashing indirectly
        let runnerSet: Set<LocalRunner> = [runner1, runner2, runner3]
        XCTAssertEqual(runnerSet.count, 2) // runner1 and runner3 are the same ID
        
        // Verify the set contains both unique runners
        XCTAssertTrue(runnerSet.contains(runner1))
        XCTAssertTrue(runnerSet.contains(runner2))
    }
    
    func testLocalRunnerEquatable() {
        let runner1 = LocalRunner(
            name: "Equality Test",
            repository: "user/equality-repo", 
            path: "/Users/user/runner"
        )
        
        var runner2 = runner1
        runner2.status = .running
        runner2.environmentVariables = ["TEST": "value"]
        
        let runner3 = LocalRunner(
            name: "Different Runner",
            repository: "user/different-repo",
            path: "/Users/user/different"
        )
        
        // Same ID means equal (regardless of other properties)
        XCTAssertEqual(runner1, runner2)
        
        // Different ID means not equal
        XCTAssertNotEqual(runner1, runner3)
        XCTAssertNotEqual(runner2, runner3)
    }
    
    func testLocalRunnerIdentifiable() {
        let runner = LocalRunner(
            name: "ID Test",
            repository: "user/id-repo",
            path: "/Users/user/runner"
        )
        
        // ID should be a valid UUID string
        XCTAssertNotNil(UUID(uuidString: runner.id))
        
        // ID should be consistent
        XCTAssertEqual(runner.id, runner.id)
    }
    
    func testEnvironmentVariablesModification() {
        var runner = LocalRunner(
            name: "Env Mod Test",
            repository: "user/env-repo",
            path: "/Users/user/runner"
        )
        
        // Start empty
        XCTAssertTrue(runner.environmentVariables.isEmpty)
        
        // Add variables
        runner.environmentVariables["VAR1"] = "value1"
        runner.environmentVariables["VAR2"] = "value2"
        
        XCTAssertEqual(runner.environmentVariables.count, 2)
        XCTAssertEqual(runner.environmentVariables["VAR1"], "value1")
        XCTAssertEqual(runner.environmentVariables["VAR2"], "value2")
        
        // Modify variable
        runner.environmentVariables["VAR1"] = "new_value1"
        XCTAssertEqual(runner.environmentVariables["VAR1"], "new_value1")
        
        // Remove variable
        runner.environmentVariables.removeValue(forKey: "VAR2")
        XCTAssertEqual(runner.environmentVariables.count, 1)
        XCTAssertNil(runner.environmentVariables["VAR2"])
    }
    
    func testScriptModification() {
        var runner = LocalRunner(
            name: "Script Mod Test",
            repository: "user/script-repo",
            path: "/Users/user/runner"
        )
        
        // Start with no scripts
        XCTAssertNil(runner.preJobScript)
        XCTAssertNil(runner.postJobScript)
        
        // Add scripts
        runner.preJobScript = "echo 'pre'"
        runner.postJobScript = "echo 'post'"
        
        XCTAssertEqual(runner.preJobScript, "echo 'pre'")
        XCTAssertEqual(runner.postJobScript, "echo 'post'")
        
        // Modify scripts
        runner.preJobScript = "echo 'modified pre'"
        runner.postJobScript = "echo 'modified post'"
        
        XCTAssertEqual(runner.preJobScript, "echo 'modified pre'")
        XCTAssertEqual(runner.postJobScript, "echo 'modified post'")
        
        // Remove scripts
        runner.preJobScript = nil
        runner.postJobScript = nil
        
        XCTAssertNil(runner.preJobScript)
        XCTAssertNil(runner.postJobScript)
    }
    
    func testLabelsModification() {
        var runner = LocalRunner(
            name: "Labels Test",
            repository: "user/labels-repo",
            path: "/Users/user/runner",
            labels: ["initial"]
        )
        
        XCTAssertEqual(runner.labels, ["initial"])
        
        // Add labels
        runner.labels.append("added")
        XCTAssertEqual(runner.labels, ["initial", "added"])
        
        // Remove labels
        runner.labels.removeAll { $0 == "initial" }
        XCTAssertEqual(runner.labels, ["added"])
        
        // Replace all labels
        runner.labels = ["replaced1", "replaced2"]
        XCTAssertEqual(runner.labels, ["replaced1", "replaced2"])
    }
    
    func testRunnerStatusEnum() {
        // Test all cases exist
        XCTAssertEqual(RunnerStatus.stopped.rawValue, "stopped")
        XCTAssertEqual(RunnerStatus.running.rawValue, "running")
        XCTAssertEqual(RunnerStatus.error.rawValue, "error")
        
        // Test display names
        XCTAssertEqual(RunnerStatus.stopped.displayName, "Stopped")
        XCTAssertEqual(RunnerStatus.running.displayName, "Running")
        XCTAssertEqual(RunnerStatus.error.displayName, "Error")
        
        // Test colors
        XCTAssertEqual(RunnerStatus.stopped.color, "gray")
        XCTAssertEqual(RunnerStatus.running.color, "green")
        XCTAssertEqual(RunnerStatus.error.color, "red")
        
        // Test CaseIterable
        let allCases = RunnerStatus.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.stopped))
        XCTAssertTrue(allCases.contains(.running))
        XCTAssertTrue(allCases.contains(.error))
    }
    
    func testRunnerStatusCodable() throws {
        let statuses: [RunnerStatus] = [.stopped, .running, .error]
        
        for status in statuses {
            let encoder = JSONEncoder()
            let data = try encoder.encode(status)
            
            let decoder = JSONDecoder()
            let decodedStatus = try decoder.decode(RunnerStatus.self, from: data)
            
            XCTAssertEqual(status, decodedStatus)
        }
    }
}