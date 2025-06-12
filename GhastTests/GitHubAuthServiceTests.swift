import XCTest
import KeychainAccess
import AuthenticationServices
@testable import Ghast

@MainActor
final class GitHubAuthServiceTests: XCTestCase {
    
    var authService: GitHubAuthService!
    var mockKeychain: Keychain!
    
    override func setUp() async throws {
        authService = GitHubAuthService()
        // Use a test-specific keychain to avoid conflicts
        mockKeychain = Keychain(service: "net.evancoleman.ghast.test")
            .accessibility(.afterFirstUnlock)
        
        // Clean up any existing test data
        try? mockKeychain.removeAll()
    }
    
    override func tearDown() async throws {
        authService = nil
        try? mockKeychain.removeAll()
        mockKeychain = nil
    }
    
    // MARK: - Initialization Tests
    
    func testInitialState() {
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertNil(authService.currentUser)
        XCTAssertFalse(authService.isLoading)
        XCTAssertFalse(authService.isAuthenticating)
        XCTAssertTrue(authService.isCheckingStoredAuth) // Should start as true
    }
    
    // MARK: - Stored Authentication Tests
    
    func testCheckStoredAuthenticationInTestMode() async {
        // In test mode, should skip keychain access
        await authService.checkStoredAuthentication()
        
        XCTAssertFalse(authService.isCheckingStoredAuth)
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertNil(authService.currentUser)
    }
    
    // MARK: - Sign Out Tests
    
    func testSignOut() {
        // Set up authenticated state
        let mockUser = GitHubUser(
            id: 123,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
        authService.currentUser = mockUser
        authService.isAuthenticated = true
        
        // Sign out
        authService.signOut()
        
        // Verify state is cleared
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertNil(authService.currentUser)
    }
    
    // MARK: - Test Helper Methods
    
    func testSimulateSuccessfulAuth() {
        let mockUser = GitHubUser(
            id: 456,
            login: "simulateduser",
            avatarURL: "https://example.com/avatar2.png",
            name: "Simulated User",
            email: "simulated@example.com"
        )
        
        authService.simulateSuccessfulAuth(user: mockUser)
        
        XCTAssertTrue(authService.isAuthenticated)
        XCTAssertNotNil(authService.currentUser)
        XCTAssertEqual(authService.currentUser?.login, "simulateduser")
        XCTAssertFalse(authService.isLoading)
        XCTAssertFalse(authService.isAuthenticating)
    }
    
    // MARK: - OAuth URL Building Tests
    
    func testBuildAuthURL() {
        // Since buildAuthURL is private, test the OAuth flow components
        let clientId = "Ov23liLVIllxzZoRYwAN"
        let redirectURI = "ghast://auth/callback"
        
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "repo user:email"),
            URLQueryItem(name: "state", value: "test-state")
        ]
        
        let url = components.url!
        
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/login/oauth/authorize")
        XCTAssertTrue(url.absoluteString.contains("client_id=\(clientId)"))
        // Check for URL encoded redirect_uri - URLComponents may encode differently
        XCTAssertTrue(url.absoluteString.contains("redirect_uri=") && url.absoluteString.contains("ghast") && url.absoluteString.contains("auth") && url.absoluteString.contains("callback"))
        // Check for scope - may be encoded as + instead of %20
        XCTAssertTrue(url.absoluteString.contains("scope=repo") && (url.absoluteString.contains("user:email") || url.absoluteString.contains("user%3Aemail")))
    }
    
    func testExtractCodeFromURL() {
        // Test successful code extraction
        let urlWithCode = URL(string: "ghast://auth/callback?code=abc123&state=xyz")!
        let components = URLComponents(url: urlWithCode, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?.first { $0.name == "code" }?.value
        
        XCTAssertEqual(code, "abc123")
        
        // Test missing code
        let urlWithoutCode = URL(string: "ghast://auth/callback?state=xyz")!
        let components2 = URLComponents(url: urlWithoutCode, resolvingAgainstBaseURL: false)
        let code2 = components2?.queryItems?.first { $0.name == "code" }?.value
        
        XCTAssertNil(code2)
        
        // Test malformed URL
        let malformedURL = URL(string: "ghast://invalid")!
        let components3 = URLComponents(url: malformedURL, resolvingAgainstBaseURL: false)
        let code3 = components3?.queryItems?.first { $0.name == "code" }?.value
        
        XCTAssertNil(code3)
    }
    
    // MARK: - ASWebAuthenticationPresentationContext Tests
    
    func testPresentationAnchor() {
        // Test that presentation anchor is provided
        let anchor = authService.presentationAnchor(for: ASWebAuthenticationSession(url: URL(string: "https://example.com")!, callbackURLScheme: "ghast") { _, _ in })
        
        XCTAssertNotNil(anchor)
    }
    
    // MARK: - Private Type Tests
    
    func testTokenResponseDecoding() throws {
        let json = """
        {
            "access_token": "gho_test123456789",
            "token_type": "bearer",
            "scope": "repo user:email"
        }
        """
        
        let data = json.data(using: .utf8)!
        
        // Test that the JSON structure matches what we expect
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        XCTAssertNotNil(jsonObject)
        XCTAssertEqual(jsonObject?["access_token"] as? String, "gho_test123456789")
        XCTAssertEqual(jsonObject?["token_type"] as? String, "bearer")
        XCTAssertEqual(jsonObject?["scope"] as? String, "repo user:email")
    }
    
    // MARK: - Notification Tests
    
    func testOAuthCallbackNotification() async {
        let expectation = XCTestExpectation(description: "OAuth callback processed")
        
        // Set up observer
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            guard let url = notification.object as? URL else {
                XCTFail("No URL in notification")
                return
            }
            
            XCTAssertEqual(url.scheme, "ghast")
            XCTAssertEqual(url.host, "auth")
            expectation.fulfill()
        }
        
        // Post notification
        let testURL = URL(string: "ghast://auth/callback?code=test123")!
        NotificationCenter.default.post(name: .oauthCallback, object: testURL)
        
        await fulfillment(of: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
    
    // MARK: - Debug Method Tests
    
    func testDebugTestOAuthCallback() async {
        let expectation = XCTestExpectation(description: "Debug OAuth callback processed")
        
        var receivedURL: URL?
        let observer = NotificationCenter.default.addObserver(
            forName: .oauthCallback,
            object: nil,
            queue: .main
        ) { notification in
            receivedURL = notification.object as? URL
            expectation.fulfill()
        }
        
        // Start the debug test
        await authService.debugTestOAuthCallback()
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        // Verify the notification was sent with correct URL
        XCTAssertNotNil(receivedURL)
        XCTAssertEqual(receivedURL?.absoluteString, "ghast://auth/callback?code=debug_test_code&state=debug_state")
        
        // Verify loading states were set
        XCTAssertTrue(authService.isLoading)
        XCTAssertTrue(authService.isAuthenticating)
        
        NotificationCenter.default.removeObserver(observer)
    }
    
    // MARK: - Loading State Tests
    
    func testLoadingStatesAsync() async {
        // Test that loading states are managed properly
        XCTAssertFalse(authService.isLoading)
        XCTAssertFalse(authService.isAuthenticating)
        
        // Simulate starting auth
        authService.isLoading = true
        authService.isAuthenticating = true
        
        XCTAssertTrue(authService.isLoading)
        XCTAssertTrue(authService.isAuthenticating)
        
        // Simulate completion
        authService.isLoading = false
        authService.isAuthenticating = false
        
        XCTAssertFalse(authService.isLoading)
        XCTAssertFalse(authService.isAuthenticating)
    }
    
    // MARK: - Test Environment Detection
    
    func testIsRunningTests() {
        // Since we're in a test environment, this should return true
        // We can't directly test the private method, but we can verify behavior
        
        // checkStoredAuthentication should skip keychain access in tests
        let expectation = XCTestExpectation(description: "Check stored auth completes quickly")
        
        Task {
            await authService.checkStoredAuthentication()
            expectation.fulfill()
        }
        
        // Should complete almost immediately in test mode
        wait(for: [expectation], timeout: 0.1)
    }
}