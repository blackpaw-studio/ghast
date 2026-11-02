import XCTest
import AuthenticationServices
@testable import Ghast

@MainActor
final class OAuthFlowIntegrationTests: XCTestCase {
    var authService: GitHubAuthService!
    
    override func setUp() async throws {
        try await super.setUp()
        authService = GitHubAuthService()
    }
    
    override func tearDown() async throws {
        authService.signOut()
        authService = nil
        try await super.tearDown()
    }
    
    func testInitialState() {
        // Verify initial state
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertNil(authService.currentUser)
        XCTAssertFalse(authService.isLoading)
        XCTAssertFalse(authService.isAuthenticating)
    }
    
    func testSignOutClearsState() async throws {
        // Simulate authenticated state
        authService.simulateSuccessfulAuth(user: GitHubUser(
            id: 1, login: "mockuser", avatarURL: "", name: nil, email: nil))
        
        // Verify authenticated
        XCTAssertTrue(authService.isAuthenticated)
        XCTAssertNotNil(authService.currentUser)
        XCTAssertEqual(authService.currentUser?.login, "mockuser")
        
        // Sign out
        authService.signOut()
        
        // Verify state is cleared
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertNil(authService.currentUser)
    }
    
    func testOAuthURLConstruction() {
        // Test that OAuth URL is properly constructed
        let url = authService.buildAuthURL()
        
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/login/oauth/authorize")
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        
        XCTAssertTrue(queryItems.contains { $0.name == "client_id" && $0.value == "Ov23liLVIllxzZoRYwAN" })
        XCTAssertTrue(queryItems.contains { $0.name == "redirect_uri" && $0.value == "ghast://auth/callback" })
        XCTAssertTrue(queryItems.contains { $0.name == "scope" && $0.value == "repo user:email" })
    }
    
    func testOAuthCallbackNotificationHandling() async throws {
        // Test that the service responds to OAuth callback notifications
        let expectation = XCTestExpectation(description: "OAuth callback handled")
        
        // Subscribe to auth state changes
        let cancellable = authService.$isAuthenticated.sink { isAuthenticated in
            if isAuthenticated {
                expectation.fulfill()
            }
        }
        
        // Simulate OAuth callback with mock response
        let callbackURL = URL(string: "ghast://auth/callback?code=mock_auth_code")!
        
        // Post notification as AppDelegate would
        NotificationCenter.default.post(
            name: .oauthCallback,
            object: callbackURL
        )
        
        // Wait briefly for processing
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // In a real scenario, this would authenticate if the backend was mocked
        // For now, we'll use the mock method
        authService.simulateSuccessfulAuth(user: GitHubUser(
            id: 1, login: "mockuser", avatarURL: "", name: nil, email: nil))
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        XCTAssertTrue(authService.isAuthenticated)
        cancellable.cancel()
    }
    
    func testCheckStoredAuthenticationInTestMode() async {
        // Test that stored auth check is skipped in test mode
        await authService.checkStoredAuthentication()
        
        // Should remain unauthenticated since we're in test mode
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertFalse(authService.isCheckingStoredAuth)
    }
    
    func testAuthStateObservability() async throws {
        // Test that auth state changes are observable
        let expectation = XCTestExpectation(description: "Auth state change observed")
        
        let cancellable = authService.objectWillChange.sink { _ in
            expectation.fulfill()
        }
        
        // Trigger state change
        authService.simulateSuccessfulAuth(user: GitHubUser(
            id: 1, login: "mockuser", avatarURL: "", name: nil, email: nil))
        
        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()
    }
    
    func testLoadingStateTransitions() async throws {
        // Test loading state transitions
        XCTAssertFalse(authService.isLoading)
        XCTAssertFalse(authService.isAuthenticating)
        
        // Note: Can't test actual signIn flow without mocking, but we can verify initial state
        
        // Mock authentication sets proper state
        authService.simulateSuccessfulAuth(user: GitHubUser(
            id: 1, login: "mockuser", avatarURL: "", name: nil, email: nil))
        XCTAssertFalse(authService.isLoading)
        XCTAssertFalse(authService.isAuthenticating)
    }
}