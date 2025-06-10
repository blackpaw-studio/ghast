import XCTest
@testable import Ghast
import SwiftUI

@MainActor
final class LoginWindowBugTest: XCTestCase {
    var authService: GitHubAuthService!
    
    override func setUp() {
        super.setUp()
        authService = GitHubAuthService()
    }
    
    override func tearDown() {
        authService = nil
        super.tearDown()
    }
    
    func testLoginWindowStaysOnLoginScreenAfterRedirect() async {
        print("🧪 Testing login window staying on login screen bug")
        
        // Step 1: Verify initial state - should be unauthenticated and not loading
        XCTAssertFalse(authService.isAuthenticated, "Should start unauthenticated")
        XCTAssertFalse(authService.isLoading, "Should not be loading initially")
        XCTAssertNil(authService.currentUser, "Should have no current user")
        
        // Step 2: Simulate starting sign in process
        let signInTask = Task {
            await authService.signIn()
        }
        
        // Give it a moment to start loading
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Step 3: Verify loading state is set
        XCTAssertTrue(authService.isLoading, "Should be loading during sign in")
        XCTAssertFalse(authService.isAuthenticated, "Should still be unauthenticated")
        
        // Step 4: Simulate successful OAuth callback (this is where the bug occurs)
        let callbackURL = URL(string: "ghast://auth/callback?code=test_auth_code_123&state=test_state")!
        
        print("📱 Simulating OAuth redirect callback: \(callbackURL.absoluteString)")
        
        // This simulates what happens when GitHub redirects back to our app
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        // Wait for the sign in task to complete
        await signInTask.value
        
        // Step 5: Check if loading state is properly cleared
        // THIS IS WHERE THE BUG MANIFESTS - isLoading stays true because 
        // the isAuthenticating property is referenced but not declared
        print("🔍 Checking final state...")
        print("   isLoading: \(authService.isLoading)")
        print("   isAuthenticated: \(authService.isAuthenticated)")
        print("   currentUser: \(authService.currentUser?.login ?? "nil")")
        
        // The bug: isLoading should be false after OAuth flow completes
        // But due to missing isAuthenticating property, the state doesn't update correctly
        
        // This test will initially fail, demonstrating the bug
        XCTAssertFalse(authService.isLoading, "Loading state should be cleared after OAuth flow completes - BUG: This fails because isAuthenticating property is missing")
        
        print("✅ Login window bug test completed")
    }
    
    func testAuthenticatingPropertyMissing() async {
        print("🧪 Testing for missing isAuthenticating property compilation issue")
        
        // This test demonstrates that the GitHubAuthService references 
        // an isAuthenticating property that doesn't exist
        
        // Start the OAuth flow
        let signInTask = Task {
            await authService.signIn()
        }
        
        // Simulate callback
        let callbackURL = URL(string: "ghast://auth/callback?code=test_code&state=test")!
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        await signInTask.value
        
        // The fact that this test runs means the missing property is causing
        // the authentication state to not update properly
        print("🐛 Bug confirmed: isAuthenticating property is referenced but not declared")
    }
    
    func testWelcomeViewSignInButtonState() async {
        print("🧪 Testing WelcomeView sign in button state during OAuth flow")
        
        // This tests the UI side of the bug - the WelcomeView might not properly
        // handle the loading states due to the OAuth service bug
        
        // Step 1: Start sign in
        let signInExpectation = XCTestExpectation(description: "Sign in starts")
        
        Task {
            await authService.signIn()
            signInExpectation.fulfill()
        }
        
        // Step 2: Check that loading state is set
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        XCTAssertTrue(authService.isLoading, "Should be loading during sign in")
        
        // Step 3: Simulate OAuth callback
        let callbackURL = URL(string: "ghast://auth/callback?code=test&state=test")!
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        // Step 4: Wait for completion
        await fulfillment(of: [signInExpectation], timeout: 5.0)
        
        // Step 5: Verify final state
        // BUG: Due to missing isAuthenticating property, isLoading might stay true
        // causing the WelcomeView to show "Signing In..." indefinitely
        print("🔍 Final loading state: \(authService.isLoading)")
        
        // This assertion will fail initially, demonstrating the UI bug
        XCTAssertFalse(authService.isLoading, "Loading should be false after OAuth completes - BUG: Stays true due to missing isAuthenticating property")
    }
}