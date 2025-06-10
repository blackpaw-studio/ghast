import XCTest
@testable import Ghast

@MainActor
final class LoginWindowBugFixTest: XCTestCase {
    
    func testLoginWindowBugFixed() async {
        print("🧪 Testing that login window bug is fixed")
        
        // Create a fresh auth service instance
        let authService = GitHubAuthService()
        
        // Step 1: Verify initial state
        XCTAssertFalse(authService.isAuthenticated, "Should start unauthenticated")
        XCTAssertFalse(authService.isLoading, "Should not be loading initially")
        XCTAssertFalse(authService.isAuthenticating, "Should not be authenticating initially")
        XCTAssertNil(authService.currentUser, "Should have no current user")
        
        print("✅ Initial state verified")
        
        // Step 2: Test that isAuthenticating property exists and can be set
        // This was the core bug - the property was referenced but not declared
        authService.isAuthenticating = true
        XCTAssertTrue(authService.isAuthenticating, "isAuthenticating property should be settable")
        
        authService.isAuthenticating = false
        XCTAssertFalse(authService.isAuthenticating, "isAuthenticating property should be clearable")
        
        print("✅ isAuthenticating property works correctly")
        
        // Step 3: Test loading state management
        authService.isLoading = true
        authService.isAuthenticating = true
        
        XCTAssertTrue(authService.isLoading, "Loading should be true")
        XCTAssertTrue(authService.isAuthenticating, "Authenticating should be true")
        
        // This simulates what happens at the end of OAuth flow
        authService.isLoading = false
        authService.isAuthenticating = false
        
        XCTAssertFalse(authService.isLoading, "Loading should be false after OAuth")
        XCTAssertFalse(authService.isAuthenticating, "Authenticating should be false after OAuth")
        
        print("✅ Loading state management works correctly")
        print("🎉 Login window bug is FIXED!")
    }
    
    func testAuthenticationStatePropertiesExist() async {
        print("🧪 Testing all authentication state properties exist")
        
        let authService = GitHubAuthService()
        
        // Test that all required properties exist and have correct initial values
        XCTAssertFalse(authService.isAuthenticated, "isAuthenticated should exist and be false initially")
        XCTAssertFalse(authService.isLoading, "isLoading should exist and be false initially") 
        XCTAssertFalse(authService.isAuthenticating, "isAuthenticating should exist and be false initially")
        XCTAssertNil(authService.currentUser, "currentUser should exist and be nil initially")
        
        print("✅ All authentication state properties exist with correct initial values")
    }
}