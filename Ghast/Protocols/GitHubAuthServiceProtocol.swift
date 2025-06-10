import Foundation
import SwiftUI

/// Protocol for GitHub authentication operations to enable testing
@MainActor
protocol GitHubAuthServiceProtocol: ObservableObject {
    var isAuthenticated: Bool { get set }
    var currentUser: GitHubUser? { get set }
    var isLoading: Bool { get set }
    var isAuthenticating: Bool { get set }
    var isCheckingStoredAuth: Bool { get set }
    
    func checkStoredAuthentication() async
    func signIn() async
    func signOut()
    func simulateSuccessfulAuth(user: GitHubUser)
    func debugTestOAuthCallback() async
}

/// Environment key for injecting auth service
struct GitHubAuthServiceKey: EnvironmentKey {
    static let defaultValue: (any GitHubAuthServiceProtocol)? = nil
}

extension EnvironmentValues {
    var gitHubAuthService: (any GitHubAuthServiceProtocol)? {
        get { self[GitHubAuthServiceKey.self] }
        set { self[GitHubAuthServiceKey.self] = newValue }
    }
}