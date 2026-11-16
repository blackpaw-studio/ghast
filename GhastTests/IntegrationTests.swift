import XCTest
@testable import Ghast

@MainActor
final class IntegrationTests: XCTestCase {
    
    func testRunnerServiceIntegration() {
        print("🧪 Testing runner service integration")
        
        let runnerService = makeTestRunnerService()
        let initialCount = runnerService.localRunners.count
        
        // Test adding a runner
        let testRunner = LocalRunner(
            name: "Integration Test Runner",
            repository: "test/repo",
            path: "/tmp/integration-test-runner"
        )
        
        runnerService.addLocalRunner(testRunner)
        XCTAssertEqual(runnerService.localRunners.count, initialCount + 1)
        
        // Test removing the runner
        runnerService.removeLocalRunner(id: testRunner.id)
        XCTAssertEqual(runnerService.localRunners.count, initialCount)
        
        print("✅ Runner service integration - PASSED")
    }
}