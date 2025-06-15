import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @EnvironmentObject var appState: AppState
    @Environment(\.gitHubAPIService) var apiService
    @State private var totalRunners = 0
    @State private var activeRunners = 0
    @State private var busyRunners = 0
    @State private var isLoadingStats = false
    @State private var showingNewRunnerFlow = false
    @State private var loadError: Error?
    @ObservedObject private var rateLimitManager = RateLimitManager.shared
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                // Rate limit warning if needed
                if rateLimitManager.isRateLimited || rateLimitManager.rateLimitInfo?.isNearLimit == true {
                    RateLimitView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // Hero Welcome Section
                heroSection
                
                // Stats Cards Grid
                statsGrid
                
                // Recent Repositories Section
                repositoriesSection
            }
            .padding(.vertical, 20)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(NSColor.controlBackgroundColor),
                    Color(NSColor.controlBackgroundColor).opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .navigationTitle("")
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
        .errorAlert(error: $loadError) {
            // Retry action
            Task {
                await loadRunnerStats()
            }
        } onReauthenticate: {
            // Re-authenticate
            authService.signOut()
            Task {
                await authService.signIn()
            }
        }
    }
    
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 12) {
                    // Welcome message with professional typography
                    VStack(alignment: .leading, spacing: 6) {
                        if let user = authService.currentUser {
                            Text("Welcome back, \(user.name ?? user.login)!")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .foregroundColor(.primary)
                        }
                        
                        Text("Manage your GitHub Actions self-hosted runners")
                            .font(.system(.title3, design: .rounded, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    // Quick stats preview
                    HStack(spacing: 16) {
                        quickStatPill(
                            icon: "server.rack",
                            value: "\(totalRunners)",
                            label: "Runners"
                        )
                        
                        quickStatPill(
                            icon: "folder.badge.gearshape",
                            value: "\(appState.repositories.count)",
                            label: "Repos"
                        )
                        
                        if activeRunners > 0 {
                            quickStatPill(
                                icon: "circle.fill",
                                value: "\(activeRunners)",
                                label: "Online",
                                color: .green
                            )
                        }
                    }
                }
                
                Spacer()
                
                // Action buttons
                VStack(spacing: 12) {
                    Button(action: {
                        showingNewRunnerFlow = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("New Runner")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.repositories.isEmpty)
                    
                    Button(action: {
                        Task {
                            await loadRunnerStats()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Refresh")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingStats)
                }
            }
        }
        .padding(24)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }
    
    private func quickStatPill(icon: String, value: String, label: String, color: Color = .blue) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
            
            Text(value)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundColor(.primary)
            
            Text(label)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Overview")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isLoadingStats {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading...")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                ModernStatCard(
                    title: "Total Runners",
                    value: isLoadingStats ? "–" : "\(totalRunners)",
                    icon: "server.rack",
                    color: .blue,
                    isLoading: isLoadingStats,
                    onTap: {
                        appState.selectedView = .localRunners
                    }
                )
                
                ModernStatCard(
                    title: "Online",
                    value: isLoadingStats ? "–" : "\(activeRunners)",
                    icon: "checkmark.circle.fill",
                    color: .green,
                    isLoading: isLoadingStats,
                    onTap: {
                        appState.selectedView = .localRunners
                    }
                )
                
                ModernStatCard(
                    title: "Busy",
                    value: isLoadingStats ? "–" : "\(busyRunners)",
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    isLoading: isLoadingStats,
                    onTap: {
                        appState.selectedView = .localRunners
                    }
                )
                
                ModernStatCard(
                    title: "Repositories",
                    value: appState.isLoadingRepositories ? "–" : "\(appState.repositories.count)",
                    icon: "folder.badge.gearshape",
                    color: .purple,
                    isLoading: appState.isLoadingRepositories,
                    onTap: {
                        if let firstRepo = appState.repositories.first {
                            appState.selectedView = .repository(firstRepo)
                            appState.selectedRepository = firstRepo
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 20)
    }
    
    private var repositoriesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent Repositories")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if appState.repositories.count > 6 {
                    Button("View All") {
                        // Navigate to full repositories view
                    }
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundColor(.blue)
                }
            }
            
            if appState.isLoadingRepositories {
                loadingState
            } else if appState.repositories.isEmpty {
                emptyState
            } else {
                repositoriesGrid
            }
        }
        .padding(20)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }
    
    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            VStack(spacing: 6) {
                Text("Loading repositories...")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundColor(.primary)
                
                Text("This may take a moment")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.secondary.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("No repositories found")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("Make sure you have access to repositories with GitHub Actions workflows.")
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            
            Button("Refresh Repositories") {
                Task {
                    await loadRunnerStats()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var repositoriesGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            ForEach(appState.repositories.prefix(6)) { repository in
                ModernRepositoryCard(repository: repository) {
                    appState.selectedView = .repository(repository)
                    appState.selectedRepository = repository
                }
            }
        }
    }
    
    private func loadRunnerStats() async {
        if appState.repositories.isEmpty { return }
        
        isLoadingStats = true
        loadError = nil
        
        var total = 0
        var active = 0
        var busy = 0
        var encounteredError: Error?
        var successfulLoads = 0
        
        // Load stats from first 10 repositories to avoid too many API calls
        for repository in appState.repositories.prefix(10) {
            do {
                let runners = try await apiService.fetchRunners(for: repository)
                total += runners.count
                active += runners.filter { $0.isOnline }.count
                busy += runners.filter { $0.busy }.count
                successfulLoads += 1
            } catch {
                // Store the first error we encounter
                if encounteredError == nil {
                    encounteredError = error
                }
                
                // If it's a rate limit or auth error, stop trying
                if let apiError = error as? GitHubAPIError {
                    switch apiError {
                    case .rateLimitExceeded, .unauthorized:
                        break
                    default:
                        continue
                    }
                }
            }
        }
        
        await MainActor.run {
            totalRunners = total
            activeRunners = active
            busyRunners = busy
            isLoadingStats = false
            
            // Only show error if we couldn't load any repositories
            if successfulLoads == 0 && encounteredError != nil {
                loadError = encounteredError
            }
        }
    }
}

struct ModernStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let onTap: (() -> Void)?
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            onTap?()
        }) {
            VStack(spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.15))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(color)
                    }
                    
                    Spacer()
                    
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if onTap != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .opacity(isHovered ? 1 : 0.6)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(value)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(title)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Rectangle()
                            .stroke(
                                isHovered ? color.opacity(0.4) : Color.primary.opacity(0.1),
                                lineWidth: 1
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(
                color: isHovered ? color.opacity(0.2) : Color.clear,
                radius: isHovered ? 8 : 0,
                x: 0,
                y: 4
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

struct ModernRepositoryCard: View {
    let repository: GitHubRepository
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(repository.isPrivate ? .orange : .green)
                        
                        Text(repository.isPrivate ? "Private" : "Public")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundColor(repository.isPrivate ? .orange : .green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill((repository.isPrivate ? Color.orange : Color.green).opacity(0.1))
                    )
                    
                    Spacer()
                    
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .opacity(isHovered ? 1 : 0.6)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(repository.name)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let description = repository.description, !description.isEmpty {
                        Text(description)
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("No description")
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.secondary.opacity(0.6))
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Rectangle()
                            .stroke(
                                isHovered ? Color.blue.opacity(0.4) : Color.primary.opacity(0.1),
                                lineWidth: 1
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(
                color: isHovered ? Color.blue.opacity(0.15) : Color.clear,
                radius: isHovered ? 8 : 0,
                x: 0,
                y: 4
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// Keep the old StatCard for backward compatibility
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
        ModernStatCard(
            title: title,
            value: value,
            icon: icon,
            color: color,
            isLoading: isLoading,
            onTap: onTap
        )
    }
}

// Keep the old DashboardRepositoryCard for backward compatibility
struct DashboardRepositoryCard: View {
    let repository: GitHubRepository
    let onTap: () -> Void
    
    var body: some View {
        ModernRepositoryCard(repository: repository, onTap: onTap)
    }
}

#Preview {
    DashboardView()
        .environmentObject(GitHubAuthService())
        .environmentObject(AppState())
}