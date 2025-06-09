import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @EnvironmentObject var appState: AppState
    @State private var totalRunners = 0
    @State private var activeRunners = 0
    @State private var busyRunners = 0
    @State private var isLoadingStats = false
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Welcome Section
                VStack(alignment: .leading, spacing: 8) {
                    if let user = authService.currentUser {
                        Text("Welcome back, \(user.name ?? user.login)!")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                    }
                    
                    Text("Manage your GitHub Actions self-hosted runners")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                
                // Stats Cards
                HStack(spacing: 16) {
                    StatCard(
                        title: "Total Runners",
                        value: isLoadingStats ? "–" : "\(totalRunners)",
                        icon: "play.circle.fill",
                        color: .blue,
                        isLoading: isLoadingStats
                    )
                    
                    StatCard(
                        title: "Online",
                        value: isLoadingStats ? "–" : "\(activeRunners)",
                        icon: "checkmark.circle.fill",
                        color: .green,
                        isLoading: isLoadingStats
                    )
                    
                    StatCard(
                        title: "Busy",
                        value: isLoadingStats ? "–" : "\(busyRunners)",
                        icon: "exclamationmark.circle.fill",
                        color: .orange,
                        isLoading: isLoadingStats
                    )
                    
                    StatCard(
                        title: "Repositories",
                        value: appState.isLoadingRepositories ? "–" : "\(appState.repositories.count)",
                        icon: "folder.fill",
                        color: .purple,
                        isLoading: appState.isLoadingRepositories
                    )
                }
                .padding(.horizontal)
                
                // Recent Repositories
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent Repositories")
                            .font(.headline)
                        Spacer()
                        Button("Refresh") {
                            Task {
                                await loadRunnerStats()
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingStats)
                    }
                    
                    if appState.isLoadingRepositories {
                        VStack {
                            ProgressView()
                            Text("Loading repositories...")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if appState.repositories.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("No repositories found")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Make sure you have access to repositories with GitHub Actions.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(appState.repositories.prefix(6)) { repository in
                                DashboardRepositoryCard(repository: repository) {
                                    appState.selectedView = .repository(repository)
                                    appState.selectedRepository = repository
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
        }
        .navigationTitle("Dashboard")
        .task {
            if !appState.repositories.isEmpty {
                await loadRunnerStats()
            }
        }
        .onChange(of: appState.repositories) { _ in
            Task {
                await loadRunnerStats()
            }
        }
    }
    
    private func loadRunnerStats() async {
        if appState.repositories.isEmpty { return }
        
        isLoadingStats = true
        var total = 0
        var active = 0
        var busy = 0
        
        // Load stats from first 10 repositories to avoid too many API calls
        for repository in appState.repositories.prefix(10) {
            do {
                let runners = try await GitHubAPIService.shared.fetchRunners(for: repository)
                total += runners.count
                active += runners.filter { $0.isOnline }.count
                busy += runners.filter { $0.busy }.count
            } catch {
                // Silently continue with other repositories
                continue
            }
        }
        
        await MainActor.run {
            totalRunners = total
            activeRunners = active
            busyRunners = busy
            isLoadingStats = false
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let isLoading: Bool
    
    init(title: String, value: String, icon: String, color: Color, isLoading: Bool = false) {
        self.title = title
        self.value = value
        self.icon = icon
        self.color = color
        self.isLoading = isLoading
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            Text(value)
                .font(.title)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DashboardRepositoryCard: View {
    let repository: GitHubRepository
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                        .foregroundColor(repository.isPrivate ? .orange : .green)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(repository.name)
                    .font(.headline)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                
                if let description = repository.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    DashboardView()
        .environmentObject(GitHubAuthService())
        .environmentObject(AppState())
}