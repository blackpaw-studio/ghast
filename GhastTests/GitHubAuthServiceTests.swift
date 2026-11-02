import XCTest
@testable import Ghast

@MainActor
final class GitHubAuthServiceTests: XCTestCase {
    
    var authService: GitHubAuthService!
    
    override func setUp() async throws {
        authService = GitHubAuthService(tokenStore: InMemoryTokenStore())
    }

    override func tearDown() async throws {
        authService = nil
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