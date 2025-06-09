import XCTest
@testable import Ghast

final class IntegrationTests: XCTestCase {
    
    func testCompleteOAuthIntegration() async {
        print("🚀 Starting complete OAuth integration test")
        
        // This test will simulate the entire OAuth flow and help us debug where it breaks
        
        let authService = GitHubAuthService()
        
        // Step 1: Test that the auth service is properly initialized
        XCTAssertFalse(authService.isAuthenticated, "Should start unauthenticated")
        XCTAssertFalse(authService.isAuthenticating, "Should not be authenticating initially")
        
        print("✅ Step 1: Auth service initialization - PASSED")
        
        // Step 2: Test notification handling (this is where the problem likely is)
        await testNotificationHandling(authService: authService)
        
        print("✅ Complete OAuth integration test finished")
    }
    
    private func testNotificationHandling(authService: GitHubAuthService) async {
        print("🔍 Testing notification handling with real auth service...")
        
        let expectation = XCTestExpectation(description: "Auth service notification handling")
        
        // Set up the observer BEFORE posting the notification (like real OAuth flow)
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            print("🔔 Test observer received notification")
            
            guard let url = notification.object as? URL else {
                print("❌ No URL in notification")
                XCTFail("No URL in notification")
                return
            }
            
            print("🔗 Test received URL: \(url.absoluteString)")
            
            // Test the same logic as GitHubAuthService
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let code = components?.queryItems?.first { $0.name == "code" }?.value
            
            if let code = code {
                print("✅ Successfully extracted code: \(String(code.prefix(10)))...")
                expectation.fulfill()
            } else {
                print("❌ Failed to extract code from URL")
                XCTFail("Failed to extract code")
            }
            
            // Clean up
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
            }
        }
        
        // Simulate the GitHub redirect
        let redirectURL = URL(string: "ghast://auth/callback?code=integration_test_code&state=test_state")!
        print("📤 Posting notification with URL: \(redirectURL.absoluteString)")
        
        NotificationCenter.default.post(name: .oauthCallback, object: redirectURL)
        
        await fulfillment(of: [expectation], timeout: 3.0)
        
        print("✅ Notification handling test completed")
    }
    
    func testActualURLHandling() {
        print("🧪 Testing actual URL handling mechanisms")
        
        // Test the URL handling that happens in GhastApp.swift
        let testURL = URL(string: "ghast://auth/callback?code=url_test_code&state=url_test")!
        
        // Test 1: AppDelegate style handling
        testAppDelegateStyleHandling(url: testURL)
        
        // Test 2: SwiftUI onOpenURL style handling  
        testSwiftUIStyleHandling(url: testURL)
        
        print("✅ URL handling mechanisms test completed")
    }
    
    private func testAppDelegateStyleHandling(url: URL) {
        print("🔍 Testing AppDelegate style URL handling...")
        
        let expectation = XCTestExpectation(description: "AppDelegate URL handling")
        
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            print("📨 AppDelegate style notification received")
            expectation.fulfill()
        }
        
        // Simulate what AppDelegate.handleGetURLEvent does
        print("📤 AppDelegate: Posting notification...")
        NotificationCenter.default.post(name: .oauthCallback, object: url)
        
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
        
        print("✅ AppDelegate style handling - PASSED")
    }
    
    private func testSwiftUIStyleHandling(url: URL) {
        print("🔍 Testing SwiftUI onOpenURL style handling...")
        
        let expectation = XCTestExpectation(description: "SwiftUI URL handling")
        
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            print("📨 SwiftUI style notification received")
            expectation.fulfill()
        }
        
        // Simulate what SwiftUI onOpenURL does
        print("📤 SwiftUI: Posting notification...")
        NotificationCenter.default.post(name: .oauthCallback, object: url)
        
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
        
        print("✅ SwiftUI style handling - PASSED")
    }
    
    func testRunnerServiceIntegration() {
        print("🧪 Testing runner service integration")
        
        let runnerService = RunnerService.shared
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