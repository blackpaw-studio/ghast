import SwiftUI

struct RepositoryDetailView: View {
    let repository: GitHubRepository
    @State private var runners: [GitHubRunner] = []
    @State private var isLoadingRunners = false
    @State private var showingAddRunner = false
    @State private var errorMessage: String?
    @StateObject private var runnerService = RunnerService.shared
    
    // Local runners for this repository
    private var localRunners: [LocalRunner] {
        runnerService.localRunners.filter { $0.repository == repository.fullName }
    }
    
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
            } else if runners.isEmpty && localRunners.isEmpty {
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
                List {
                    // Local Runners Section
                    if !localRunners.isEmpty {
                        Section {
                            ForEach(localRunners) { runner in
                                LocalRunnerRepositoryRowView(runner: runner)
                            }
                        } header: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text("Local Runners")
                                Spacer()
                                Text("\(localRunners.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // Remote Runners Section
                    if !runners.isEmpty {
                        Section {
                            ForEach(runners) { runner in
                                RunnerRowView(runner: runner, repository: repository) {
                                    Task {
                                        await loadRunners()
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: "cloud")
                                Text("Remote Runners")
                                Spacer()
                                Text("\(runners.count)")
                                    .foregroundColor(.secondary)
                            }
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

struct LocalRunnerRepositoryRowView: View {
    let runner: LocalRunner
    @StateObject private var runnerService = RunnerService.shared
    @State private var showingDeleteAlert = false
    
    // Find the current runner from the service to get live status updates
    private var currentRunner: LocalRunner? {
        runnerService.localRunners.first { $0.id == runner.id }
    }
    
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
                    
                    // Local indicator
                    Text("LOCAL")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.2))
                        .foregroundColor(.purple)
                        .clipShape(Capsule())
                    
                    Spacer()
                    
                    // Control buttons - use current runner for live updates
                    HStack(spacing: 4) {
                        if currentRunner?.status == .running {
                            Button("Stop") {
                                runnerService.stopRunner(id: runner.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        } else {
                            Button("Start") {
                                Task {
                                    do {
                                        try await runnerService.startRunner(id: runner.id)
                                    } catch {
                                        print("Failed to start runner: \(error)")
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                        
                        Menu {
                            Button("View Logs") {
                                // TODO: Navigate to logs view - for now just print
                                print("Navigate to logs for runner: \(runner.name)")
                            }
                            
                            Divider()
                            
                            Button("Remove", role: .destructive) {
                                showingDeleteAlert = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundColor(.secondary)
                        }
                        .controlSize(.mini)
                    }
                }
                
                HStack(spacing: 8) {
                    Text(currentRunner?.status.displayName ?? runner.status.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.2))
                        .foregroundColor(statusColor)
                        .clipShape(Capsule())
                    
                    Text("macOS")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
                
                if !runner.labels.isEmpty {
                    HStack {
                        ForEach(runner.labels.prefix(3), id: \.self) { label in
                            Text(label)
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
        }
        .padding(.vertical, 4)
        .alert("Remove Runner", isPresented: $showingDeleteAlert) {
            Button("Remove", role: .destructive) {
                runnerService.removeLocalRunner(id: runner.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to remove '\(runner.name)'? This will stop the runner if it's running.")
        }
    }
    
    private var statusColor: Color {
        switch currentRunner?.status ?? runner.status {
        case .stopped: return .gray
        case .running: return .green
        case .error: return .red
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