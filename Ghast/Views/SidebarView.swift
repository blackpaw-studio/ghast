import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    
    var filteredRepositories: [GitHubRepository] {
        if searchText.isEmpty {
            return appState.repositories
        } else {
            return appState.repositories.filter { repo in
                repo.name.localizedCaseInsensitiveContains(searchText) ||
                repo.fullName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        List {
            Button(action: {
                appState.selectedView = .dashboard
            }) {
                Label("Dashboard", systemImage: "chart.bar.fill")
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(appState.selectedView == .dashboard ? .accentColor : .primary)
            
            Button(action: {
                appState.selectedView = .localRunners
            }) {
                Label("Local Runners", systemImage: "server.rack")
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(appState.selectedView == .localRunners ? .accentColor : .primary)
            
            Section {
                if appState.isLoadingRepositories {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading repositories...")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if appState.repositories.isEmpty {
                    Text("No repositories found")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(filteredRepositories) { repository in
                        Button(action: {
                            appState.selectedView = .repository(repository)
                            appState.selectedRepository = repository
                        }) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                                        .font(.caption)
                                        .foregroundColor(repository.isPrivate ? .orange : .green)
                                    Text(repository.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                if let description = repository.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(
                            appState.selectedView == .repository(repository) ? .accentColor : .primary
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Repositories")
                    Spacer()
                    Button(action: {
                        Task { await loadRepositories() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(appState.isLoadingRepositories)
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search repositories")
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
                                    .scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(Color.secondary)
                            }
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                            .clipped()
                            
                            Text(user.login)
                                .font(.caption)
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
        .task {
            if appState.repositories.isEmpty {
                await loadRepositories()
            }
        }
    }
    
    private func loadRepositories() async {
        appState.isLoadingRepositories = true
        do {
            let repositories = try await GitHubAPIService.shared.fetchRepositories()
            await MainActor.run {
                appState.repositories = repositories
                appState.isLoadingRepositories = false
            }
        } catch {
            await MainActor.run {
                appState.isLoadingRepositories = false
            }
            print("Failed to load repositories: \(error)")
        }
    }
}

#Preview {
    NavigationSplitView {
        SidebarView()
            .environmentObject(GitHubAuthService())
            .environmentObject(AppState())
    } detail: {
        Text("Detail View")
    }
}