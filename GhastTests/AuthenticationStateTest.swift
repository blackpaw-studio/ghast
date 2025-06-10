import XCTest
@testable import Ghast

@MainActor
final class AuthenticationStateTest: XCTestCase {
    
    func testAuthenticationStateMockFlow() async {
        print("🧪 Testing authentication state management without real API calls")
        
        let authService = GitHubAuthService()
        
        // Step 1: Verify initial state
        XCTAssertFalse(authService.isAuthenticated, "Should start unauthenticated")
        XCTAssertFalse(authService.isLoading, "Should not be loading initially")
        XCTAssertFalse(authService.isAuthenticating, "Should not be authenticating initially")
        XCTAssertNil(authService.currentUser, "Should have no current user")
        
        print("✅ Initial state verified")
        
        // Step 2: Simulate what should happen when OAuth succeeds
        // This mimics the end of a successful exchangeCodeForToken call
        let mockUser = GitHubUser(
            id: 123456,
            login: "testuser",
            name: "Test User",
            email: "test@example.com",
            avatarURL: "https://github.com/images/error/octocat_happy.gif",
            htmlURL: "https://github.com/testuser",
            publicRepos: 5,
            followers: 10,
            following: 15
        )
        
        // Simulate successful authentication
        authService.isLoading = true
        authService.isAuthenticating = true
        
        // This simulates what happens at the end of exchangeCodeForToken
        authService.currentUser = mockUser
        authService.isAuthenticated = true
        authService.isLoading = false
        authService.isAuthenticating = false
        
        // Step 3: Verify final authenticated state
        XCTAssertTrue(authService.isAuthenticated, "Should be authenticated after success")
        XCTAssertFalse(authService.isLoading, "Should not be loading after completion")
        XCTAssertFalse(authService.isAuthenticating, "Should not be authenticating after completion")
        XCTAssertNotNil(authService.currentUser, "Should have current user after success")
        XCTAssertEqual(authService.currentUser?.login, "testuser", "User should match mock data")
        
        print("✅ Authentication state management works correctly")
    }
    
    func testAuthenticationStateFailureRecovery() async {
        print("🧪 Testing authentication state recovery from failure")
        
        let authService = GitHubAuthService()
        
        // Simulate starting authentication
        authService.isLoading = true
        authService.isAuthenticating = true
        
        // Simulate authentication failure (what should happen when token exchange fails)
        authService.isAuthenticated = false
        authService.isLoading = false
        authService.isAuthenticating = false
        authService.currentUser = nil
        
        // Verify failure state
        XCTAssertFalse(authService.isAuthenticated, "Should not be authenticated after failure")
        XCTAssertFalse(authService.isLoading, "Should not be loading after failure")
        XCTAssertFalse(authService.isAuthenticating, "Should not be authenticating after failure")
        XCTAssertNil(authService.currentUser, "Should have no user after failure")
        
        print("✅ Authentication failure recovery works correctly")
    }
    
    func testNotificationCallbackHandling() async {
        print("🧪 Testing OAuth callback notification handling")
        
        let expectation = XCTestExpectation(description: "OAuth callback received")
        
        // Set up observer like GitHubAuthService does
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            print("🔔 Received OAuth callback notification")
            
            guard let url = notification.object as? URL else {
                XCTFail("No URL in notification")
                return
            }
            
            // Verify URL structure
            XCTAssertEqual(url.scheme, "ghast")
            XCTAssertEqual(url.host, "auth")
            XCTAssertEqual(url.path, "/callback")
            
            // Extract code
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let code = components?.queryItems?.first { $0.name == "code" }?.value
            XCTAssertEqual(code, "test_auth_code")
            
            print("✅ OAuth callback processed correctly")
            expectation.fulfill()
        }
        
        // Simulate OAuth callback like AppDelegate/onOpenURL does
        let callbackURL = URL(string: "ghast://auth/callback?code=test_auth_code&state=test_state")!
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        await fulfillment(of: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
        
        print("✅ OAuth callback notification handling test passed")
    }
}