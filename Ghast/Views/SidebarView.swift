import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @EnvironmentObject var appState: AppState
    @Environment(\.gitHubAPIService) var apiService
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
        VStack(spacing: 0) {
            // Modern header with branding
            modernHeader
            
            // Navigation content
            ScrollView {
                VStack(spacing: 8) {
                    // Main navigation items
                    VStack(spacing: 4) {
                        modernNavItem(
                            title: "Dashboard",
                            icon: "chart.line.uptrend.xyaxis",
                            isSelected: appState.selectedView == .dashboard,
                            color: .blue
                        ) {
                            appState.selectedView = .dashboard
                        }
                        
                        modernNavItem(
                            title: "Local Runners", 
                            icon: "server.rack",
                            isSelected: appState.selectedView == .localRunners,
                            color: .green
                        ) {
                            appState.selectedView = .localRunners
                        }
                        
                        modernNavItem(
                            title: "Settings",
                            icon: "gearshape.fill",
                            isSelected: appState.selectedView == .settings,
                            color: .purple
                        ) {
                            appState.selectedView = .settings
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    
                    // Repositories section
                    repositoriesSection
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search repositories")
        .navigationTitle("")
        .frame(minWidth: 320)
        .task {
            if appState.repositories.isEmpty {
                await loadRepositories()
            }
        }
    }
    
    private var modernHeader: some View {
        VStack(spacing: 16) {
            // App branding
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ghast")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("GitHub Actions Tool")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial)
    }
    
    private func modernNavItem(
        title: String,
        icon: String,
        isSelected: Bool,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? color.opacity(0.2) : Color.clear)
                        .frame(width: 28, height: 28)
                    
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? color : .secondary)
                }
                
                Text(title)
                    .font(.system(.body, design: .rounded, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? color : .primary)
                
                Spacer()
                
                if isSelected {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var repositoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.orange)
                    
                    Text("Repositories")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Refresh button
                Button(action: {
                    Task { await loadRepositories() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                        )
                }
                .buttonStyle(.plain)
                .disabled(appState.isLoadingRepositories)
                .opacity(appState.isLoadingRepositories ? 0.6 : 1.0)
                
                // Repository count badge
                if !appState.repositories.isEmpty {
                    Text("\(filteredRepositories.count)")
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.08))
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            // Repository list
            if appState.isLoadingRepositories {
                modernLoadingState
            } else if appState.repositories.isEmpty {
                modernEmptyState
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(filteredRepositories) { repository in
                        modernRepositoryRow(repository: repository)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
    
    private var modernLoadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.9)
            
            Text("Loading repositories...")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
    
    private var modernEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.secondary.opacity(0.6))
            
            VStack(spacing: 4) {
                Text("No repositories")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("Check your access permissions")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
    
    private func modernRepositoryRow(repository: GitHubRepository) -> some View {
        Button(action: {
            appState.selectedView = .repository(repository)
            appState.selectedRepository = repository
        }) {
            HStack(spacing: 10) {
                // Repository status icon
                ZStack {
                    Circle()
                        .fill((repository.isPrivate ? Color.orange : Color.green).opacity(0.15))
                        .frame(width: 24, height: 24)
                    
                    Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(repository.isPrivate ? .orange : .green)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let description = repository.description, !description.isEmpty {
                        Text(description)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                Spacer()
                
                // Selection indicator
                if appState.selectedView == .repository(repository) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(appState.selectedView == .repository(repository) ? Color.blue.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func loadRepositories() async {
        guard !appState.isLoadingRepositories else { return }
        
        do {
            appState.isLoadingRepositories = true
            let repos = try await apiService.fetchRepositories()
            appState.repositories = repos
        } catch {
            print("Failed to load repositories: \(error)")
        }
        
        appState.isLoadingRepositories = false
    }
}

#Preview {
    SidebarView()
        .environmentObject(GitHubAuthService())
        .environmentObject(AppState())
}