import Foundation
@testable import Ghast

/// Mock GitHubAuthService for testing that prevents any real authentication attempts
@MainActor
class MockGitHubAuthService: GitHubAuthService {
    
    override func checkStoredAuthentication() async {
        // Do nothing - prevent actual keychain access or authentication
        print("Mock: checkStoredAuthentication() called - doing nothing")
        isCheckingStoredAuth = false
    }
    
    override func signIn() async {
        // Do nothing - prevent actual OAuth flow
        print("Mock: signIn() called - doing nothing")
        isLoading = false
        isAuthenticating = false
    }
    
    override func signOut() {
        // Just update state without keychain access
        isAuthenticated = false
        currentUser = nil
    }
    
    override func debugTestOAuthCallback() async {
        print("Mock: debugTestOAuthCallback() called - doing nothing")
    }
    
    /// Helper to set up authenticated state for testing
    func setAuthenticatedState(user: GitHubUser) {
        self.currentUser = user
        self.isAuthenticated = true
        self.isCheckingStoredAuth = false
        self.isLoading = false
        self.isAuthenticating = false
    }
    
    /// Helper to set up unauthenticated state for testing
    func setUnauthenticatedState() {
        self.currentUser = nil
        self.isAuthenticated = false
        self.isCheckingStoredAuth = false
        self.isLoading = false
        self.isAuthenticating = false
    }
}