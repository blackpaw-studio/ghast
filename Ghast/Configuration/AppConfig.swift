import Foundation

enum AppConfig {
    // MARK: - OAuth Configuration
    
    /// GitHub OAuth Client ID
    static var githubClientId: String {
        // First check environment variable
        if let envValue = ProcessInfo.processInfo.environment["GHAST_GITHUB_CLIENT_ID"] {
            return envValue
        }
        
        // Fall back to build configuration (set in project.yml)
        #if DEBUG
        // For development, require environment variable
        fatalError("GHAST_GITHUB_CLIENT_ID environment variable not set. Please set it to your GitHub OAuth App Client ID.")
        #else
        // For release builds, this should be set via build configuration
        return Bundle.main.object(forInfoDictionaryKey: "GITHUB_CLIENT_ID") as? String ?? ""
        #endif
    }
    
    /// GitHub OAuth Client Secret
    static var githubClientSecret: String? {
        // First check environment variable
        if let envValue = ProcessInfo.processInfo.environment["GHAST_GITHUB_CLIENT_SECRET"] {
            return envValue
        }
        
        // For release builds, we should use device flow or proxy server
        // Client secret should never be embedded in the app
        #if DEBUG
        // For development, allow nil to encourage device flow implementation
        return nil
        #else
        // Production apps should never include client secret
        return nil
        #endif
    }
    
    /// OAuth Redirect URI
    static let githubRedirectURI = "ghast://auth/callback"
    
    /// Whether to use device flow for OAuth (recommended for native apps)
    static var useDeviceFlow: Bool {
        // Use device flow if client secret is not available
        return githubClientSecret == nil
    }
}