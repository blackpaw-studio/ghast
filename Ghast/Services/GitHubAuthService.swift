import Foundation
import SwiftUI
import os

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

    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "auth")

    private let deviceFlow: any DeviceFlowClienting
    private let tokenStore: any TokenStore
    private let fetchUser: @MainActor (String) async throws -> GitHubUser
    private let useToken: @MainActor (String) -> Void
    private var signInTask: Task<Void, Never>?
    /// Identity of the sign-in attempt allowed to touch state, Keychain and the API
    /// service. Cleared on cancel, replaced on each `signIn()`, so an abandoned attempt
    /// that finishes late cannot clobber a newer one.
    private var currentAttempt: UUID?

    /// - Parameters:
    ///   - deviceFlow: Device Flow transport; production default talks to github.com.
    ///   - fetchUser: Loads the user for a fresh token. Must have no side effects; the
    ///     default calls the GitHub API with the token explicitly.
    ///   - tokenStore: Persists the verified token; the default uses the Keychain.
    ///   - useToken: Hands a stored token to the API client. Only runs for the current
    ///     attempt, after the token was persisted. The default configures
    ///     `GitHubAPIService.shared`.
    init(
        deviceFlow: any DeviceFlowClienting = DeviceFlowClient(),
        tokenStore: any TokenStore = KeychainTokenStore(),
        fetchUser: (@MainActor (String) async throws -> GitHubUser)? = nil,
        useToken: (@MainActor (String) -> Void)? = nil
    ) {
        self.deviceFlow = deviceFlow
        self.tokenStore = tokenStore
        self.fetchUser = fetchUser ?? { try await GitHubAPIService.shared.fetchCurrentUser(token: $0) }
        self.useToken = useToken ?? { GitHubAPIService.shared.setAccessToken($0) }
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
        let attempt = UUID()
        currentAttempt = attempt
        let task = Task { await runSignIn(attempt) }
        signInTask = task
        await task.value
    }

    func cancelSignIn() {
        currentAttempt = nil
        signInTask?.cancel()
        signInTask = nil
        if case .signedIn = signInState { return }
        signInState = .idle
    }

    private func isCurrent(_ attempt: UUID) -> Bool {
        currentAttempt == attempt && !Task.isCancelled
    }

    private func runSignIn(_ attempt: UUID) async {
        do {
            let code = try await deviceFlow.requestCode(scopes: Self.scopes)
            guard isCurrent(attempt) else { return }
            signInState = .awaitingUser(code)

            let token = try await deviceFlow.pollForToken(code)
            guard isCurrent(attempt) else { return }
            let user = try await fetchUser(token)
            guard isCurrent(attempt) else { return }

            try tokenStore.write(token)
            useToken(token)
            currentUser = user
            isAuthenticated = true
            signInState = .signedIn
        } catch {
            guard isCurrent(attempt) else { return }
            if error is TokenStoreError {
                Self.logger.error("Failed to store token: \(String(describing: error), privacy: .public)")
            }
            signInState = Self.isCancellation(error) ? .idle : .failed(Self.failure(for: error))
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func failure(for error: Error) -> DeviceFlowError {
        if let error = error as? DeviceFlowError { return error }
        if let error = error as? TokenStoreError { return .storage(error.description) }
        return .network(error.localizedDescription)
    }

    func signOut() {
        cancelSignIn()
        isAuthenticated = false
        currentUser = nil
        signInState = .idle
        do {
            try tokenStore.delete()
        } catch {
            Self.logger.error("Failed to delete stored token: \(String(describing: error), privacy: .public)")
        }
    }
    
    func simulateSuccessfulAuth(user: GitHubUser) {
        self.currentUser = user
        self.isAuthenticated = true
        self.signInState = .signedIn
    }
    
    private func checkExistingAuth() async {
        do {
            guard let token = try tokenStore.read() else { return }

            let user = try await GitHubAPIService.shared.fetchCurrentUser(token: token)
            await MainActor.run {
                self.currentUser = user
                self.isAuthenticated = true
                GitHubAPIService.shared.setAccessToken(token)
            }
        } catch {
            // Token is invalid or keychain access failed, remove it silently
            try? tokenStore.delete()
        }
    }
}
