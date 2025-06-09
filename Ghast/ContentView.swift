import SwiftUI

struct ContentView: View {
    @StateObject private var authService = GitHubAuthService()
    @StateObject private var appState = AppState()
    
    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainAppView()
                    .environmentObject(authService)
                    .environmentObject(appState)
            } else {
                WelcomeView()
                    .environmentObject(authService)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

struct MainAppView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            switch appState.selectedView {
            case .dashboard:
                DashboardView()
            case .repository(let repo):
                RepositoryDetailView(repository: repo)
            case .localRunners:
                LocalRunnersView()
            case .settings:
                SettingsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Settings") {
                        appState.selectedView = .settings
                    }
                    Divider()
                    Button("Sign Out") {
                        authService.signOut()
                    }
                } label: {
                    if let user = authService.currentUser {
                        AsyncImage(url: URL(string: user.avatarURL)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                        }
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.circle")
                    }
                }
            }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var selectedView: SelectedView = .dashboard
    @Published var repositories: [GitHubRepository] = []
    @Published var isLoadingRepositories = false
    @Published var selectedRepository: GitHubRepository?
    
    enum SelectedView: Equatable {
        case dashboard
        case repository(GitHubRepository)
        case localRunners
        case settings
    }
}

#Preview {
    ContentView()
}