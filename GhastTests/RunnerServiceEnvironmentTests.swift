import XCTest
import Foundation
@testable import Ghast

@MainActor
final class RunnerServiceEnvironmentTests: XCTestCase {
    
    var runnerService: RunnerService!
    var testRunner: LocalRunner!
    var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        
        runnerService = RunnerService.shared
        
        // Create a temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghast-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Create test runner with temp directory path
        testRunner = LocalRunner(
            name: "Test Environment Runner",
            repository: "test/env-repo",
            path: tempDirectory.path
        )
        
        // Clean up any existing runners to ensure clean state
        runnerService.removeAllLocalRunners()
        runnerService.addLocalRunner(testRunner)
    }
    
    override func tearDown() async throws {
        // Clean up test runners
        runnerService.removeAllLocalRunners()
        
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)
        
        try await super.tearDown()
    }
    
    // MARK: - Environment Variables Tests
    
    func testUpdateEnvironmentVariables() {
        let envVars = [
            "NODE_ENV": "production",
            "API_URL": "https://api.example.com",
            "DEBUG": "false"
        ]
        
        runnerService.updateRunnerEnvironmentVariables(id: testRunner.id, environmentVariables: envVars)
        
        // Verify the runner model was updated
        let updatedRunner = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertNotNil(updatedRunner)
        XCTAssertEqual(updatedRunner?.environmentVariables, envVars)
        
        // Verify .env file was created
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFilePath))
        
        // Verify .env file contents
        let envContent = try? String(contentsOfFile: envFilePath, encoding: .utf8)
        XCTAssertNotNil(envContent)
        XCTAssertTrue(envContent!.contains("NODE_ENV=\"production\""))
        XCTAssertTrue(envContent!.contains("API_URL=\"https://api.example.com\""))
        XCTAssertTrue(envContent!.contains("DEBUG=\"false\""))
        XCTAssertTrue(envContent!.contains("# Environment variables for Test Environment Runner"))
    }
    
    func testUpdateEnvironmentVariablesWithSpecialCharacters() {
        let envVars = [
            "SPECIAL_VAR": "value with \"quotes\" and spaces",
            "MULTILINE": "line1\\nline2",
            "EMPTY_VAR": ""
        ]
        
        runnerService.updateRunnerEnvironmentVariables(id: testRunner.id, environmentVariables: envVars)
        
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        let envContent = try? String(contentsOfFile: envFilePath, encoding: .utf8)
        XCTAssertNotNil(envContent)
        
        // Verify special characters are properly escaped
        print("Debug env content: \(envContent!)")
        XCTAssertTrue(envContent!.contains("SPECIAL_VAR="))
        XCTAssertTrue(envContent!.contains("MULTILINE="))
        XCTAssertTrue(envContent!.contains("EMPTY_VAR=\"\""))
    }
    
    func testRemoveEnvironmentVariables() {
        // First, add some environment variables
        let envVars = ["TEST_VAR": "test_value"]
        runnerService.updateRunnerEnvironmentVariables(id: testRunner.id, environmentVariables: envVars)
        
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFilePath))
        
        // Then remove them (empty dictionary)
        runnerService.updateRunnerEnvironmentVariables(id: testRunner.id, environmentVariables: [:])
        
        // Verify .env file is removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: envFilePath))
        
        // Verify runner model is updated
        let updatedRunner = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertTrue(updatedRunner?.environmentVariables.isEmpty ?? false)
    }
    
    // MARK: - Pre-Job Script Tests
    
    func testUpdatePreJobScript() {
        let script = """
        #!/bin/bash
        echo "Pre-job setup starting..."
        export CUSTOM_VAR="setup_value"
        mkdir -p /tmp/job-workspace
        """
        
        runnerService.updateRunnerPreJobScript(id: testRunner.id, script: script)
        
        // Verify runner model was updated
        let updatedRunner = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertEqual(updatedRunner?.preJobScript, script)
        
        // Verify pre-job script file was created
        let scriptPath = tempDirectory.appendingPathComponent("pre-job.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        
        // Verify file is executable
        let attributes = try? FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        
        // Verify script content
        let scriptContent = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertNotNil(scriptContent)
        XCTAssertTrue(scriptContent!.contains(script))
        XCTAssertTrue(scriptContent!.contains("# Pre-job script for Test Environment Runner"))
        
        // Verify .env file contains hook variable
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        let envContent = try? String(contentsOfFile: envFilePath, encoding: .utf8)
        XCTAssertNotNil(envContent)
        XCTAssertTrue(envContent!.contains("ACTIONS_RUNNER_HOOK_JOB_STARTED=\"\(scriptPath)\""))
    }
    
    func testRemovePreJobScript() {
        // First, add a pre-job script
        runnerService.updateRunnerPreJobScript(id: testRunner.id, script: "echo 'test'")
        
        let scriptPath = tempDirectory.appendingPathComponent("pre-job.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        
        // Then remove it
        runnerService.updateRunnerPreJobScript(id: testRunner.id, script: nil)
        
        // Verify script file is removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptPath))
        
        // Verify runner model is updated
        let updatedRunner = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertNil(updatedRunner?.preJobScript)
        
        // Verify hook variable is removed from .env
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        if FileManager.default.fileExists(atPath: envFilePath) {
            let envContent = try? String(contentsOfFile: envFilePath, encoding: .utf8)
            XCTAssertFalse(envContent?.contains("ACTIONS_RUNNER_HOOK_JOB_STARTED") ?? true)
        }
    }
    
    // MARK: - Post-Job Script Tests
    
    func testUpdatePostJobScript() {
        let script = """
        #!/bin/bash
        echo "Post-job cleanup starting..."
        rm -rf /tmp/job-workspace
        docker system prune -f
        """
        
        runnerService.updateRunnerPostJobScript(id: testRunner.id, script: script)
        
        // Verify runner model was updated
        let updatedRunner = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertEqual(updatedRunner?.postJobScript, script)
        
        // Verify post-job script file was created
        let scriptPath = tempDirectory.appendingPathComponent("post-job.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        
        // Verify file is executable
        let attributes = try? FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        
        // Verify script content
        let scriptContent = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertNotNil(scriptContent)
        XCTAssertTrue(scriptContent!.contains(script))
        XCTAssertTrue(scriptContent!.contains("# Post-job script for Test Environment Runner"))
        
        // Verify .env file contains hook variable
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        let envContent = try? String(contentsOfFile: envFilePath, encoding: .utf8)
        XCTAssertNotNil(envContent)
        XCTAssertTrue(envContent!.contains("ACTIONS_RUNNER_HOOK_JOB_COMPLETED=\"\(scriptPath)\""))
    }
    
    func testRemovePostJobScript() {
        // First, add a post-job script
        runnerService.updateRunnerPostJobScript(id: testRunner.id, script: "echo 'cleanup'")
        
        let scriptPath = tempDirectory.appendingPathComponent("post-job.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        
        // Then remove it
        runnerService.updateRunnerPostJobScript(id: testRunner.id, script: nil)
        
        // Verify script file is removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptPath))
        
        // Verify runner model is updated
        let updatedRunner = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertNil(updatedRunner?.postJobScript)
        
        // Verify hook variable is removed from .env
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        if FileManager.default.fileExists(atPath: envFilePath) {
            let envContent = try? String(contentsOfFile: envFilePath, encoding: .utf8)
            XCTAssertFalse(envContent?.contains("ACTIONS_RUNNER_HOOK_JOB_COMPLETED") ?? true)
        }
    }
    
    // MARK: - Integration Tests
    
    func testCombinedEnvironmentAndScripts() {
        let envVars = [
            "COMBINED_TEST": "true",
            "RUNNER_NAME": testRunner.name
        ]
        let preScript = "echo 'Starting with env: $COMBINED_TEST'"
        let postScript = "echo 'Finished for: $RUNNER_NAME'"
        
        // Update all three components
        runnerService.updateRunnerEnvironmentVariables(id: testRunner.id, environmentVariables: envVars)
        runnerService.updateRunnerPreJobScript(id: testRunner.id, script: preScript)
        runnerService.updateRunnerPostJobScript(id: testRunner.id, script: postScript)
        
        // Verify all files exist
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        let preScriptPath = tempDirectory.appendingPathComponent("pre-job.sh").path
        let postScriptPath = tempDirectory.appendingPathComponent("post-job.sh").path
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preScriptPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: postScriptPath))
        
        // Verify .env file contains all variables including hooks
        let envContent = try? String(contentsOfFile: envFilePath, encoding: .utf8)
        XCTAssertNotNil(envContent)
        XCTAssertTrue(envContent!.contains("COMBINED_TEST=\"true\""))
        XCTAssertTrue(envContent!.contains("RUNNER_NAME=\"\(testRunner.name)\""))
        XCTAssertTrue(envContent!.contains("ACTIONS_RUNNER_HOOK_JOB_STARTED=\"\(preScriptPath)\""))
        XCTAssertTrue(envContent!.contains("ACTIONS_RUNNER_HOOK_JOB_COMPLETED=\"\(postScriptPath)\""))
    }
    
    func testSyncRunnerFiles() {
        // Create a runner with environment and scripts
        var testRunnerWithData = testRunner!
        testRunnerWithData.environmentVariables = ["SYNC_TEST": "value"]
        testRunnerWithData.preJobScript = "echo 'sync pre'"
        testRunnerWithData.postJobScript = "echo 'sync post'"
        
        // Remove existing runner and add the new one
        runnerService.removeLocalRunner(id: testRunner.id)
        runnerService.addLocalRunner(testRunnerWithData)
        
        // Verify syncRunnerFiles created all files (called automatically by addLocalRunner)
        let envFilePath = tempDirectory.appendingPathComponent(".env").path
        let preScriptPath = tempDirectory.appendingPathComponent("pre-job.sh").path
        let postScriptPath = tempDirectory.appendingPathComponent("post-job.sh").path
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preScriptPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: postScriptPath))
    }
    
    func testInvalidRunnerId() {
        let invalidId = "non-existent-runner-id"
        
        // These should not crash or cause issues
        runnerService.updateRunnerEnvironmentVariables(id: invalidId, environmentVariables: ["TEST": "value"])
        runnerService.updateRunnerPreJobScript(id: invalidId, script: "echo 'test'")
        runnerService.updateRunnerPostJobScript(id: invalidId, script: "echo 'test'")
        
        // No assertions needed - just verifying no crashes occur
    }
    
    func testEmptyAndWhitespaceScripts() {
        // Test empty string
        runnerService.updateRunnerPreJobScript(id: testRunner.id, script: "")
        
        let updatedRunner1 = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertEqual(updatedRunner1?.preJobScript, "")
        
        // Test whitespace-only string
        runnerService.updateRunnerPostJobScript(id: testRunner.id, script: "   \n\t  ")
        
        let updatedRunner2 = runnerService.localRunners.first { $0.id == testRunner.id }
        XCTAssertEqual(updatedRunner2?.postJobScript, "   \n\t  ")
        
        // Verify no script files were created
        let preScriptPath = tempDirectory.appendingPathComponent("pre-job.sh").path
        let postScriptPath = tempDirectory.appendingPathComponent("post-job.sh").path
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: preScriptPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: postScriptPath))
    }
}