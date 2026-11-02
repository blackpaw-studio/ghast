import XCTest
import Observation
@testable import Ghast

@MainActor
final class OAuthFlowIntegrationTests: XCTestCase {
    var authService: GitHubAuthService!
    
    override func setUp() async throws {
        try await super.setUp()
        authService = GitHubAuthService(apiService: MockGitHubAPIService(), tokenStore: InMemoryTokenStore())
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
        
        withObservationTracking {
            _ = authService.isAuthenticated
        } onChange: {
            expectation.fulfill()
        }
        
        // Trigger state change
        authService.simulateSuccessfulAuth(user: GitHubUser(
            id: 1, login: "mockuser", avatarURL: "", name: nil, email: nil))
        
        await fulfillment(of: [expectation], timeout: 1.0)
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