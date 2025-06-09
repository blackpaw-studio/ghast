import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @State private var selectedView: SidebarItem = .dashboard
    
    var body: some View {
        List(selection: $selectedView) {
            Section("Management") {
                SidebarRow(item: .dashboard)
                SidebarRow(item: .runners)
                SidebarRow(item: .environments)
            }
            
            Section("Account") {
                SidebarRow(item: .settings)
            }
        }
        .navigationTitle("Ghast")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let user = authService.currentUser {
                    Menu {
                        Button("Sign Out") {
                            authService.signOut()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            AsyncImage(url: URL(string: user.avatarURL)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle()
                                    .fill(Color.secondary)
                            }
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                            
                            Text(user.login)
                                .font(.caption)
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    
    var body: some View {
        NavigationLink(value: item) {
            Label(item.title, systemImage: item.systemImage)
        }
    }
}

enum SidebarItem: String, CaseIterable, Hashable {
    case dashboard
    case runners
    case environments
    case settings
    
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .runners: return "Runners"
        case .environments: return "Environments"
        case .settings: return "Settings"
        }
    }
    
    var systemImage: String {
        switch self {
        case .dashboard: return "gauge"
        case .runners: return "play.circle"
        case .environments: return "globe"
        case .settings: return "gear"
        }
    }
}

#Preview {
    NavigationSplitView {
        SidebarView()
            .environmentObject(GitHubAuthService())
    } detail: {
        Text("Detail View")
    }
}