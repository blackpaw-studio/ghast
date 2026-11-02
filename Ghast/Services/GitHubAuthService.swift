import Foundation
import SwiftUI
import KeychainAccess
import Alamofire

enum SignInState: Equatable {
    case idle
    case awaitingUser(DeviceCode)
    case failed(DeviceFlowError)
    case signedIn
}

@MainActor
class GitHubAuthService: GitHubAuthServiceProtocol {
    static let scopes = ["repo", "user:email"]

    @Published var isAuthenticated = false {
        didSet {
            #if DEBUG
            print("🔐 OAuth: isAuthenticated changed to \(isAuthenticated)")
            #endif
        }
    }
    @Published var currentUser: GitHubUser?
    @Published var signInState: SignInState = .idle
    @Published var isCheckingStoredAuth = true // Start with true to prevent login screen flash

    /// Derived from `signInState` for views that only need "is a sign-in in flight".
    var isLoading: Bool { isAuthenticating }
    var isAuthenticating: Bool {
        if case .awaitingUser = signInState { return true }
        return false
    }

    private var keychain: Keychain {
        return Keychain(service: "net.evancoleman.ghast")
            .accessibility(.afterFirstUnlock)
    }

    private let deviceFlow: any DeviceFlowClienting
    private let completeSignInOverride: (@MainActor (String) async throws -> GitHubUser)?
    private var signInTask: Task<Void, Never>?

    /// - Parameters:
    ///   - deviceFlow: Device Flow transport; production default talks to github.com.
    ///   - completeSignIn: Turns a fresh token into the signed-in user. The default
    ///     stores the token in Keychain, hands it to the API service and fetches the user.
    init(
        deviceFlow: any DeviceFlowClienting = DeviceFlowClient(),
        completeSignIn: (@MainActor (String) async throws -> GitHubUser)? = nil
    ) {
        self.deviceFlow = deviceFlow
        self.completeSignInOverride = completeSignIn
        // isCheckingStoredAuth is already true from the property declaration
        // This prevents the login screen flash without triggering keychain access
    }

    /// Check if the app is running in a test environment
    private func isRunningTests() -> Bool {
        return NSClassFromString("XCTest") != nil || 
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
               ProcessInfo.processInfo.arguments.contains { $0.contains("test") }
    }
    
    func checkStoredAuthentication() async {
        defer { isCheckingStoredAuth = false }
        
        // Skip keychain access during tests
        if isRunningTests() {
            #if DEBUG
            print("🔐 OAuth: Test mode detected - skipping stored auth check")
            #endif
            return
        }
        
        await checkExistingAuth()
    }
    
    /// Runs the whole Device Flow. Returns when sign-in succeeds, fails or is cancelled;
    /// the outcome is published through `signInState`. Calling again (Try again)
    /// cancels any run in flight and requests a fresh code.
    func signIn() async {
        signInTask?.cancel()
        if signInState != .idle { signInState = .idle }
        let task = Task { await runSignIn() }
        signInTask = task
        await task.value
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .signedIn = signInState { return }
        signInState = .idle
    }

    private func runSignIn() async {
        do {
            let code = try await deviceFlow.requestCode(scopes: Self.scopes)
            try Task.checkCancellation()
            signInState = .awaitingUser(code)
            let token = try await deviceFlow.pollForToken(code)
            try Task.checkCancellation()
            let user = try await completeSignIn(token)
            try Task.checkCancellation()
            currentUser = user
            isAuthenticated = true
            signInState = .signedIn
        } catch is CancellationError {
            // cancelSignIn() or a newer signIn() owns the state.
        } catch let error as DeviceFlowError {
            signInState = .failed(error)
        } catch {
            signInState = .failed(.network(error.localizedDescription))
        }
    }

    private func completeSignIn(_ token: String) async throws -> GitHubUser {
        if let completeSignInOverride { return try await completeSignInOverride(token) }
        try? keychain.set(token, key: "github_token") // still works without persistent storage
        GitHubAPIService.shared.setAccessToken(token)
        do {
            return try await GitHubAPIService.shared.fetchCurrentUser()
        } catch {
            try? keychain.remove("github_token")
            throw error
        }
    }

    func signOut() {
        cancelSignIn()
        isAuthenticated = false
        currentUser = nil
        signInState = .idle
        do {
            try keychain.remove("github_token")
        } catch {
            #if DEBUG
            print("🔐 Warning: Failed to remove token from keychain: \(error)")
            #endif
        }
    }
    
    func simulateSuccessfulAuth(user: GitHubUser) {
        self.currentUser = user
        self.isAuthenticated = true
        self.signInState = .signedIn
    }
    
    private func checkExistingAuth() async {
        do {
            // Check if key exists before trying to get it
            guard try keychain.contains("github_token") else {
                return
            }
            
            guard let token = try keychain.get("github_token") else {
                return
            }
            
            let user = try await GitHubAPIService.shared.fetchCurrentUser(token: token)
            await MainActor.run {
                self.currentUser = user
                self.isAuthenticated = true
                GitHubAPIService.shared.setAccessToken(token)
            }
        } catch {
            // Token is invalid or keychain access failed, remove it silently
            try? keychain.remove("github_token")
        }
    }
}
