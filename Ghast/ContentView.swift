import SwiftUI
import Foundation

struct ContentView: View {
    let authService: GitHubAuthService
    
    var body: some View {
        Group {
            if authService.isCheckingStoredAuth {
                // Show loading state while checking for stored authentication
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading...")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            } else if authService.isAuthenticated {
                FocusMainView()
                    .environment(authService)
            } else {
                // Signed out: this window closes and Welcome opens (see `AuthWindowSwitch`).
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .switchesWindowsOnAuthChange(authService, in: .main)
    }
}

#Preview {
    let apiService = GitHubAPIService()
    ContentView(authService: GitHubAuthService(apiService: apiService))
        .environment(RunnerService())
        .environment(\.gitHubAPIService, apiService)
}
