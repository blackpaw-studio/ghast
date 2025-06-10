import Foundation
import SwiftUI
import AuthenticationServices
import KeychainAccess
import Alamofire

@MainActor
class GitHubAuthService: NSObject, ObservableObject {
    @Published var isAuthenticated = false {
        didSet {
            print("🔐 OAuth: isAuthenticated changed to \(isAuthenticated)")
        }
    }
    @Published var currentUser: GitHubUser?
    @Published var isLoading = false
    @Published var isAuthenticating = false
    
    private let keychain = Keychain(service: "net.evancoleman.ghast")
    private let clientId = "Ov23liLVIllxzZoRYwAN"
    private let redirectURI = "ghast://auth/callback"
    
    private var authSession: ASWebAuthenticationSession?
    
    override init() {
        super.init()
        checkExistingAuth()
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
                print("🔐 OAuth: Timeout reached, cancelling OAuth flow")
            }
            
            // Wait for first task to complete (either OAuth or timeout)
            await group.next()
            group.cancelAll()
        }
    }
    
    func signOut() {
        isAuthenticated = false
        currentUser = nil
        try? keychain.remove("github_token")
    }
    
    // Test helper method - DO NOT USE IN PRODUCTION
    func simulateSuccessfulAuth(user: GitHubUser) {
        self.currentUser = user
        self.isAuthenticated = true
        self.isLoading = false
        self.isAuthenticating = false
    }
    
    // Debug method to test OAuth callback without browser
    func debugTestOAuthCallback() async {
        print("🔐 DEBUG: Starting debug OAuth test")
        
        isLoading = true
        isAuthenticating = true
        
        // Simulate the callback URL that GitHub would send
        let callbackURL = URL(string: "ghast://auth/callback?code=debug_test_code&state=debug_state")!
        
        print("🔐 DEBUG: Posting notification for URL: \(callbackURL.absoluteString)")
        
        // Post the notification just like the real callback would
        NotificationCenter.default.post(name: .oauthCallback, object: callbackURL)
        
        print("🔐 DEBUG: Notification posted, OAuth flow should continue...")
    }
    
    private func checkExistingAuth() {
        if let token = try? keychain.get("github_token") {
            Task {
                do {
                    let user = try await GitHubAPIService.shared.fetchCurrentUser(token: token)
                    await MainActor.run {
                        self.currentUser = user
                        self.isAuthenticated = true
                        GitHubAPIService.shared.setAccessToken(token)
                    }
                } catch {
                    // Token is invalid, remove it
                    try? keychain.remove("github_token")
                }
            }
        }
    }
    
    private func performOAuthFlow() async {
        let authURL = buildAuthURL()
        
        print("🔐 OAuth: Starting OAuth flow")
        print("🔐 OAuth: Auth URL: \(authURL.absoluteString)")
        
        // Open URL in default browser
        NSWorkspace.shared.open(authURL)
        
        // Set up notification observer for URL callback
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .oauthCallback,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                print("🔐 OAuth: Received callback notification")
                guard let callbackURL = notification.object as? URL else {
                    print("🔐 OAuth: ERROR - No URL in notification object")
                    continuation.resume()
                    return
                }
                
                print("🔐 OAuth: Callback URL: \(callbackURL.absoluteString)")
                
                guard let code = self?.extractCode(from: callbackURL) else {
                    print("🔐 OAuth: ERROR - Failed to extract authorization code from URL")
                    continuation.resume()
                    return
                }
                
                print("🔐 OAuth: Successfully extracted code: \(String(code.prefix(10)))...")
                
                // Remove observer
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                    print("🔐 OAuth: Removed notification observer")
                }
                
                Task {
                    print("🔐 OAuth: Starting token exchange")
                    await self?.exchangeCodeForToken(code)
                    continuation.resume()
                }
            }
            
            print("🔐 OAuth: Set up notification observer, waiting for callback...")
        }
    }
    
    private func buildAuthURL() -> URL {
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
        print("🔐 OAuth: Starting token exchange for code: \(String(code.prefix(10)))...")
        
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
            print("🔐 OAuth: Sending token request to GitHub")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🔐 OAuth: Token response status: \(httpResponse.statusCode)")
            }
            
            // Debug: Print raw response
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔐 OAuth: Token response: \(responseString)")
            }
            
            if let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) {
                print("🔐 OAuth: Successfully decoded token response")
                try keychain.set(tokenResponse.accessToken, key: "github_token")
                GitHubAPIService.shared.setAccessToken(tokenResponse.accessToken)
                
                do {
                    print("🔐 OAuth: Fetching user info")
                    let user = try await GitHubAPIService.shared.fetchCurrentUser()
                    
                    // Atomic state update on MainActor
                    await MainActor.run {
                        print("🔐 OAuth: Setting user and authentication state")
                        self.currentUser = user
                        self.isAuthenticated = true
                        self.isAuthenticating = false
                    }
                    print("🔐 OAuth: Authentication completed successfully!")
                } catch {
                    print("🔐 OAuth: ERROR - User fetch failed: \(error)")
                    print("🔐 OAuth: ERROR - Error type: \(type(of: error))")
                    if let afError = error as? AFError {
                        print("🔐 OAuth: ERROR - AFError details: \(afError.localizedDescription)")
                        if case .responseValidationFailed(let reason) = afError {
                            print("🔐 OAuth: ERROR - Validation failed reason: \(reason)")
                        }
                    }
                    
                    // Clean up on user fetch failure
                    await MainActor.run {
                        self.isAuthenticated = false
                        self.isAuthenticating = false
                        self.currentUser = nil
                    }
                    try? keychain.remove("github_token")
                }
            } else {
                print("🔐 OAuth: ERROR - Failed to decode token response")
                await MainActor.run {
                    self.isAuthenticated = false
                    self.isAuthenticating = false
                }
            }
        } catch {
            print("🔐 OAuth: Token exchange error: \(error)")
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