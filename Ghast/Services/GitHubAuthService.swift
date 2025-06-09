import Foundation
import SwiftUI
import AuthenticationServices
import KeychainAccess

@MainActor
class GitHubAuthService: NSObject, ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: GitHubUser?
    @Published var isLoading = false
    
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
        defer { isLoading = false }
        
        await performOAuthFlow()
    }
    
    func signOut() {
        isAuthenticated = false
        currentUser = nil
        try? keychain.remove("github_token")
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
                
                print("🔐 OAuth: Fetching user info")
                // Fetch user info
                let user = try await GitHubAPIService.shared.fetchCurrentUser()
                await MainActor.run {
                    print("🔐 OAuth: Setting user and authentication state")
                    self.currentUser = user
                    self.isAuthenticated = true
                    self.isAuthenticating = false
                }
                print("🔐 OAuth: Authentication completed successfully!")
            } else {
                print("🔐 OAuth: ERROR - Failed to decode token response")
                await MainActor.run {
                    self.isAuthenticating = false
                }
            }
        } catch {
            print("🔐 OAuth: Token exchange error: \(error)")
            await MainActor.run {
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