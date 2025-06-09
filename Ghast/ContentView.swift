import SwiftUI

struct ContentView: View {
    @StateObject private var authService = GitHubAuthService()
    
    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainAppView()
                    .environmentObject(authService)
            } else {
                WelcomeView()
                    .environmentObject(authService)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

struct MainAppView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DashboardView()
        }
    }
}

#Preview {
    ContentView()
}