import Foundation
@testable import Ghast

/// Mock GitHubAuthService for testing that prevents any real authentication attempts
@MainActor
class MockGitHubAuthService: GitHubAuthService {

    init() {
        super.init(apiService: MockGitHubAPIService(), tokenStore: InMemoryTokenStore())
    }
    
    override func checkStoredAuthentication() async {
        // Do nothing - prevent actual keychain access or authentication
        print("Mock: checkStoredAuthentication() called - doing nothing")
        isCheckingStoredAuth = false
    }
    
    override func signIn() async {
        // Do nothing - prevent actual device flow requests
        print("Mock: signIn() called - doing nothing")
    }
    
    override func signOut() {
        // Just update state without keychain access
        isAuthenticated = false
        currentUser = nil
        signInState = .idle
    }
    
    /// Helper to set up authenticated state for testing
    func setAuthenticatedState(user: GitHubUser) {
        self.currentUser = user
        self.isAuthenticated = true
        self.isCheckingStoredAuth = false
        self.signInState = .signedIn
    }
    
    /// Helper to set up unauthenticated state for testing
    func setUnauthenticatedState() {
        self.currentUser = nil
        self.isAuthenticated = false
        self.isCheckingStoredAuth = false
        self.signInState = .idle
    }
    
    /// Helper to put the login view in a specific Device Flow state
    func setSignInState(_ state: SignInState) {
        self.signInState = state
    }
}
