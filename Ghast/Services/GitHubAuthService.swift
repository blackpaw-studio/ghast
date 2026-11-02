import Foundation
import SwiftUI
import AuthenticationServices
import KeychainAccess
import Alamofire

@MainActor
class GitHubAuthService: NSObject, GitHubAuthServiceProtocol {
    @Published var isAuthenticated = false {
        didSet {
            #if DEBUG
            print("🔐 OAuth: isAuthenticated changed to \(isAuthenticated)")
            #endif
        }
    }
    @Published var currentUser: GitHubUser?
    @Published var isLoading = false
    @Published var isAuthenticating = false
    @Published var isCheckingStoredAuth = true // Start with true to prevent login screen flash
    
    private var keychain: Keychain {
        let accessGroup = "net.evancoleman.ghast"
        return Keychain(service: "net.evancoleman.ghast", accessGroup: accessGroup)
            .accessibility(.afterFirstUnlock)
    }
    private let clientId = "Ov23liLVIllxzZoRYwAN"
    private let redirectURI = "ghast://auth/callback"
    
    private var authSession: ASWebAuthenticationSession?
    
    override init() {
        super.init()
        
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
    
    func signIn() async {
        isLoading = true
        isAuthenticating = true
        defer { 
            isLoading = false
            isAuthenticating = false
        }
        
        // Add timeout to prevent hanging indefinitely
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.performOAuthFlow()
            }
            
            group.addTask {
                // 60 second timeout for OAuth flow
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                #if DEBUG
                print("🔐 OAuth: Timeout reached, cancelling OAuth flow")
                #endif
            }
            
            // Wait for first task to complete (either OAuth or timeout)
            await group.next()
            group.cancelAll()
        }
    }
    
    func signOut() {
        isAuthenticated = false
        currentUser = nil
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
        self.isLoading = false
        self.isAuthenticating = false
    }
    
    func debugTestOAuthCallback() async {
        #if DEBUG
        print("🔐 DEBUG: Starting debug OAuth test")
        #endif
        
        isLoading = true
        isAuthenticating = true
        
        let callbackURL = URL(string: "ghast://auth/callback?code=debug_test_code&state=debug_state")!
        
        #if DEBUG
        print("🔐 DEBUG: Posting notification for URL: \(callbackURL.absoluteString)")
        #endif
        
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        #if DEBUG
        print("🔐 DEBUG: Notification posted, OAuth flow should continue...")
        #endif
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
    
    private func performOAuthFlow() async {
        let authURL = buildAuthURL()
        
        
        // Don't open browser during tests
        if !isRunningTests() {
            // Open URL in default browser
            NSWorkspace.shared.open(authURL)
        }
        
        // Set up notification observer for URL callback
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .oauthCallback,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let callbackURL = notification.object as? URL else {
                    continuation.resume()
                    return
                }
                
                guard let code = self?.extractCode(from: callbackURL) else {
                    continuation.resume()
                    return
                }
                
                // Remove observer
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }
                
                Task {
                    await self?.exchangeCodeForToken(code)
                    continuation.resume()
                }
            }
            
        }
    }
    
    func buildAuthURL() -> URL {
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "repo user:email"),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        return components.url!
    }
    
    private func extractCode(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        
        return queryItems.first { $0.name == "code" }?.value
    }
    
    private func exchangeCodeForToken(_ code: String) async {
        
        let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "client_id": clientId,
            "client_secret": "0d2d7ddfe0cbc94c9f28a53cf02a09f4d0d3b48b",
            "code": code
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) {
                do {
                    try keychain.set(tokenResponse.accessToken, key: "github_token")
                } catch {
                    // Continue anyway as we can still function without persistent storage
                }
                GitHubAPIService.shared.setAccessToken(tokenResponse.accessToken)
                
                do {
                    let user = try await GitHubAPIService.shared.fetchCurrentUser()
                    
                    // Atomic state update on MainActor
                    await MainActor.run {
                        self.currentUser = user
                        self.isAuthenticated = true
                        self.isAuthenticating = false
                    }
                } catch {
                    
                    // Clean up on user fetch failure
                    await MainActor.run {
                        self.isAuthenticated = false
                        self.isAuthenticating = false
                        self.currentUser = nil
                    }
                    try? keychain.remove("github_token")
                }
            } else {
                await MainActor.run {
                    self.isAuthenticated = false
                    self.isAuthenticating = false
                }
            }
        } catch {
            await MainActor.run {
                self.isAuthenticated = false
                self.isAuthenticating = false
            }
        }
    }
}

extension GitHubAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

private struct TokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let scope: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
    }
}