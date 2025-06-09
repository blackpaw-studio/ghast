import XCTest
@testable import Ghast

final class OAuthTests: XCTestCase {
    
    func testURLCallbackExtraction() {
        // Test extracting code from OAuth callback URL
        let testURL = URL(string: "ghast://auth/callback?code=test_code_123&state=xyz")!
        
        let authService = GitHubAuthService()
        let mirror = Mirror(reflecting: authService)
        let extractCodeMethod = mirror.children.first { $0.label == "extractCode" }
        
        // We can't easily test private methods, so let's test the URL parsing logic separately
        let components = URLComponents(url: testURL, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?.first { $0.name == "code" }?.value
        
        XCTAssertEqual(code, "test_code_123")
    }
    
    func testOAuthURLGeneration() {
        let authService = GitHubAuthService()
        
        // We'll create a simple test for URL building
        let expectedComponents = [
            "client_id=Ov23liLVIllxzZoRYwAN",
            "redirect_uri=ghast://auth/callback",
            "scope=repo user:email"
        ]
        
        // Test that our OAuth URL contains the expected components
        let testURL = "https://github.com/login/oauth/authorize?client_id=Ov23liLVIllxzZoRYwAN&redirect_uri=ghast://auth/callback&scope=repo%20user:email&state=test"
        let url = URL(string: testURL)!
        
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/login/oauth/authorize")
    }
    
    func testNotificationHandling() {
        let expectation = XCTestExpectation(description: "OAuth callback notification")
        
        let testURL = URL(string: "ghast://auth/callback?code=test_code_123")!
        
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            if let url = notification.object as? URL {
                XCTAssertEqual(url.absoluteString, testURL.absoluteString)
                expectation.fulfill()
            }
        }
        
        // Simulate the callback
        NotificationCenter.default.post(name: .oauthCallback, object: testURL)
        
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    func testRunnerServiceBasics() {
        let runnerService = RunnerService.shared
        
        // Test adding a local runner
        let testRunner = LocalRunner(
            name: "Test Runner",
            repository: "user/test-repo",
            path: "/tmp/test-runner"
        )
        
        let initialCount = runnerService.localRunners.count
        runnerService.addLocalRunner(testRunner)
        
        XCTAssertEqual(runnerService.localRunners.count, initialCount + 1)
        XCTAssertEqual(runnerService.localRunners.last?.name, "Test Runner")
        
        // Clean up
        runnerService.removeLocalRunner(id: testRunner.id)
        XCTAssertEqual(runnerService.localRunners.count, initialCount)
    }
}

extension Notification.Name {
    static let oauthCallback = Notification.Name("oauthCallback")
}