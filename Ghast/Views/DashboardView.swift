import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var authService: GitHubAuthService
    @StateObject private var runnerService = RunnerService()
    @State private var repositories: [GitHubRepository] = []
    @State private var isLoading = true
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Loading repositories...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(repositories) { repo in
                                RepositoryCard(repository: repo)
                                    .environmentObject(runnerService)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") {
                        loadRepositories()
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task {
            loadRepositories()
        }
    }
    
    private func loadRepositories() {
        isLoading = true
        Task {
            do {
                repositories = try await GitHubAPIService.shared.fetchRepositories()
            } catch {
                print("Error loading repositories: \(error)")
            }
            isLoading = false
        }
    }
}

struct RepositoryCard: View {
    let repository: GitHubRepository
    @EnvironmentObject var runnerService: RunnerService
    @State private var runners: [GitHubRunner] = []
    @State private var isLoadingRunners = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repository.name)
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    if let description = repository.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                if repository.isPrivate {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            
            if isLoadingRunners {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading runners...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                RunnerSummaryView(runners: runners)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .task {
            await loadRunners()
        }
    }
    
    private func loadRunners() async {
        isLoadingRunners = true
        do {
            runners = try await GitHubAPIService.shared.fetchRunners(for: repository)
        } catch {
            print("Error loading runners for \(repository.name): \(error)")
        }
        isLoadingRunners = false
    }
}

struct RunnerSummaryView: View {
    let runners: [GitHubRunner]
    
    var body: some View {
        HStack {
            Label("\(runners.count)", systemImage: "play.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            if !runners.isEmpty {
                let onlineCount = runners.filter { $0.status == "online" }.count
                Label("\(onlineCount) online", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(onlineCount > 0 ? .green : .secondary)
            }
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(GitHubAuthService())
}