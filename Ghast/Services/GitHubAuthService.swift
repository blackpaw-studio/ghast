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
        
        // Debug: Print the OAuth URL
        print("🔗 Opening OAuth URL: \(authURL.absoluteString)")
        
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
                guard let callbackURL = notification.object as? URL,
                      let code = self?.extractCode(from: callbackURL) else {
                    print("Failed to extract authorization code")
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
                try keychain.set(tokenResponse.accessToken, key: "github_token")
                GitHubAPIService.shared.setAccessToken(tokenResponse.accessToken)
                
                // Fetch user info
                let user = try await GitHubAPIService.shared.fetchCurrentUser()
                await MainActor.run {
                    self.currentUser = user
                    self.isAuthenticated = true
                }
            }
        } catch {
            print("Token exchange error: \(error)")
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