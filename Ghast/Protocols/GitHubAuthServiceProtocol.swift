import Foundation
import SwiftUI

/// Protocol for GitHub authentication operations to enable testing
@MainActor
protocol GitHubAuthServiceProtocol: AnyObject, Observable {
    var isAuthenticated: Bool { get set }
    var currentUser: GitHubUser? { get set }
    var signInState: SignInState { get }
    var isLoading: Bool { get }
    var isAuthenticating: Bool { get }
    var isCheckingStoredAuth: Bool { get set }
    
    func checkStoredAuthentication() async
    func signIn() async
    func cancelSignIn()
    func signOut()
    func simulateSuccessfulAuth(user: GitHubUser)
}

/// Environment key for injecting auth service
struct GitHubAuthServiceKey: EnvironmentKey {
    // Computed: a stored static of a non-Sendable type is rejected in Swift 6 mode.
    static var defaultValue: (any GitHubAuthServiceProtocol)? { nil }
}

extension EnvironmentValues {
    var gitHubAuthService: (any GitHubAuthServiceProtocol)? {
        get { self[GitHubAuthServiceKey.self] }
        set { self[GitHubAuthServiceKey.self] = newValue }
    }
}