import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @EnvironmentObject var appState: AppState
    @State private var totalRunners = 0
    @State private var activeRunners = 0
    @State private var busyRunners = 0
    @State private var isLoadingStats = false
    @State private var showingNewRunnerFlow = false
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Welcome Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
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
                        
                        Spacer()
                        
                        Button("New Runner") {
                            showingNewRunnerFlow = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(appState.repositories.isEmpty)
                    }
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
                        isLoading: isLoadingStats,
                        onTap: {
                            appState.selectedView = .localRunners
                        }
                    )
                    
                    StatCard(
                        title: "Online",
                        value: isLoadingStats ? "–" : "\(activeRunners)",
                        icon: "checkmark.circle.fill",
                        color: .green,
                        isLoading: isLoadingStats,
                        onTap: {
                            appState.selectedView = .localRunners
                        }
                    )
                    
                    StatCard(
                        title: "Busy",
                        value: isLoadingStats ? "–" : "\(busyRunners)",
                        icon: "exclamationmark.circle.fill",
                        color: .orange,
                        isLoading: isLoadingStats,
                        onTap: {
                            appState.selectedView = .localRunners
                        }
                    )
                    
                    StatCard(
                        title: "Repositories",
                        value: appState.isLoadingRepositories ? "–" : "\(appState.repositories.count)",
                        icon: "folder.fill",
                        color: .purple,
                        isLoading: appState.isLoadingRepositories,
                        onTap: {
                            // Navigate to first repository if available
                            if let firstRepo = appState.repositories.first {
                                appState.selectedView = .repository(firstRepo)
                                appState.selectedRepository = firstRepo
                            }
                        }
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
        .sheet(isPresented: $showingNewRunnerFlow) {
            NewRunnerFlowView(repositories: appState.repositories)
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
    let onTap: (() -> Void)?
    
    init(title: String, value: String, icon: String, color: Color, isLoading: Bool = false, onTap: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.icon = icon
        self.color = color
        self.isLoading = isLoading
        self.onTap = onTap
    }
    
    var body: some View {
        Group {
            if let onTap = onTap {
                Button(action: onTap) {
                    cardContent
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { isHovered in
                    // Add visual feedback for hover state
                }
            } else {
                cardContent
            }
        }
    }
    
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(onTap != nil ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
        )
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