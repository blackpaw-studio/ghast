import SwiftUI

struct RepositoryDetailView: View {
    let repository: GitHubRepository
    @State private var runners: [GitHubRunner] = []
    @State private var isLoadingRunners = false
    @State private var showingAddRunner = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                        .foregroundColor(repository.isPrivate ? .orange : .green)
                    Text(repository.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Spacer()
                    Button("Add Runner") {
                        showingAddRunner = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                if let description = repository.description {
                    Text(description)
                        .foregroundColor(.secondary)
                }
                
                Text(repository.fullName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Runners List
            if isLoadingRunners {
                VStack {
                    ProgressView()
                    Text("Loading runners...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if runners.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No runners configured")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Add a self-hosted runner to start running GitHub Actions on your own hardware.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Add Runner") {
                        showingAddRunner = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(runners) { runner in
                    RunnerRowView(runner: runner, repository: repository) {
                        Task {
                            await loadRunners()
                        }
                    }
                }
            }
        }
        .navigationTitle(repository.name)
        .sheet(isPresented: $showingAddRunner) {
            AddRunnerView(repository: repository) {
                Task {
                    await loadRunners()
                }
            }
        }
        .task {
            await loadRunners()
        }
        .refreshable {
            await loadRunners()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
    }
    
    private func loadRunners() async {
        isLoadingRunners = true
        do {
            let fetchedRunners = try await GitHubAPIService.shared.fetchRunners(for: repository)
            await MainActor.run {
                self.runners = fetchedRunners
                self.isLoadingRunners = false
                self.errorMessage = nil
            }
        } catch {
            await MainActor.run {
                self.isLoadingRunners = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

struct RunnerRowView: View {
    let runner: GitHubRunner
    let repository: GitHubRepository
    let onRunnerDeleted: () -> Void
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(runner.name)
                        .font(.headline)
                    
                    if runner.busy {
                        Text("BUSY")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    
                    Spacer()
                }
                
                HStack(spacing: 8) {
                    Text(runner.os.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                    
                    Text(runner.status.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !runner.labels.isEmpty {
                    HStack {
                        ForEach(runner.labels.prefix(3)) { label in
                            Text(label.name)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .clipShape(Capsule())
                        }
                        
                        if runner.labels.count > 3 {
                            Text("+\(runner.labels.count - 3)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Spacer()
            
            Menu {
                Button("Remove Runner", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.secondary)
            }
            .disabled(isDeleting)
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove Runner",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await deleteRunner()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to remove the runner '\(runner.name)'? This action cannot be undone.")
        }
    }
    
    private var statusColor: Color {
        switch runner.status {
        case "online":
            return runner.busy ? .orange : .green
        case "offline":
            return .red
        default:
            return .gray
        }
    }
    
    private func deleteRunner() async {
        isDeleting = true
        do {
            try await GitHubAPIService.shared.deleteRunner(runnerId: runner.id, from: repository)
            await MainActor.run {
                onRunnerDeleted()
                isDeleting = false
            }
        } catch {
            await MainActor.run {
                isDeleting = false
            }
            print("Failed to delete runner: \(error)")
        }
    }
}

#Preview {
    RepositoryDetailView(repository: GitHubRepository(
        id: 1,
        name: "Sample Repo",
        fullName: "user/sample-repo",
        description: "A sample repository for testing",
        isPrivate: false,
        owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: "User", email: nil),
        htmlURL: "https://github.com/user/sample-repo"
    ))
}