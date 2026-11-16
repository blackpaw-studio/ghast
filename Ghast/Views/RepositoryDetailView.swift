import SwiftUI

struct RepositoryDetailView: View {
    let repository: GitHubRepository
    
    var body: some View {
        ScopedRunnersPanel(scope: repository.runnerScope, repository: repository) { addRunner in
            modernHeader(addRunner: addRunner)
        }
    }
    
    private func modernHeader(addRunner: @escaping () -> Void) -> some View {
        VStack(spacing: 20) {
            // Repository info with modern styling
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.blue.opacity(0.3), radius: 12, x: 0, y: 4)
                    
                    Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(repository.name)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 8) {
                        Text(repository.fullName)
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                        
                        // Privacy badge
                        HStack(spacing: 4) {
                            Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(repository.isPrivate ? .orange : .green)
                            Text(repository.isPrivate ? "Private" : "Public")
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(repository.isPrivate ? .orange : .green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((repository.isPrivate ? Color.orange : Color.green).opacity(0.1))
                                .overlay(
                                    Capsule()
                                        .stroke((repository.isPrivate ? Color.orange : Color.green).opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                    
                    if let description = repository.description, !description.isEmpty {
                        Text(description)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                // Add runner button
                AddRunnerHeaderButton(action: addRunner)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }
}


struct ModernLocalRunnerCard: View {
    let runner: LocalRunner
    @Environment(RunnerService.self) private var runnerService
    @State private var isHovered = false
    
    // Find the current runner from the service to get live status updates
    private var currentRunner: LocalRunner? {
        runnerService.localRunners.first { $0.id == runner.id }
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Status indicator with modern styling
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }
            
            // Runner info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(runner.name)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    // Local badge
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.purple)
                        Text("LOCAL")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.purple)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.purple.opacity(0.1))
                            .overlay(
                                Capsule()
                                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                            )
                    )
                    
                    Spacer()
                }
                
                HStack(spacing: 8) {
                    // Status badge
                    Text(currentRunner?.status.displayName ?? runner.status.displayName)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(statusColor.opacity(0.1))
                                .overlay(
                                    Capsule()
                                        .stroke(statusColor.opacity(0.3), lineWidth: 1)
                                )
                        )
                    
                    // Platform badge
                    Text("macOS")
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.1))
                        )
                }
                
                // Labels if any
                if !runner.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(runner.labels.prefix(2), id: \.self) { label in
                            Text(label)
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.blue.opacity(0.1))
                                )
                        }
                        
                        if runner.labels.count > 2 {
                            Text("+\(runner.labels.count - 2)")
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Control buttons
            HStack(spacing: 8) {
                if currentRunner?.status == .running {
                    Button("Stop") {
                        runnerService.stopRunner(id: runner.id)
                    }
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.1))
                            .overlay(
                                Capsule()
                                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
                            )
                    )
                    .buttonStyle(.plain)
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
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color.green, Color.green.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
                }
                
                Menu {
                    Button("View Logs") {
                        print("Navigate to logs for runner: \(runner.name)")
                    }
                    
                    Divider()
                    
                    Button("Remove", role: .destructive) {
                        runnerService.removeLocalRunner(id: runner.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            Rectangle()
                .fill(isHovered ? Color.primary.opacity(0.02) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
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

struct ModernRemoteRunnerCard: View {
    let runner: GitHubRunner
    let scope: RunnerScope
    let onRunnerDeleted: () -> Void
    @State private var isHovered = false
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @Environment(\.gitHubAPIService) private var apiService
    
    var body: some View {
        HStack(spacing: 16) {
            // Status indicator with modern styling
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }
            
            // Runner info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(runner.name)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    // Remote badge
                    HStack(spacing: 4) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("REMOTE")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.1))
                            .overlay(
                                Capsule()
                                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
                            )
                    )
                    
                    // Busy indicator
                    if runner.busy {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(.orange)
                            Text("BUSY")
                                .font(.system(.caption2, design: .rounded, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.1))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                    
                    Spacer()
                }
                
                HStack(spacing: 8) {
                    // Status badge
                    Text(runner.status.capitalized)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(statusColor.opacity(0.1))
                                .overlay(
                                    Capsule()
                                        .stroke(statusColor.opacity(0.3), lineWidth: 1)
                                )
                        )
                    
                    // Platform badge
                    Text(runner.os.capitalized)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.1))
                        )
                }
                
                // Labels if any
                if !runner.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(runner.labels.prefix(2)) { label in
                            Text(label.name)
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.blue.opacity(0.1))
                                )
                        }
                        
                        if runner.labels.count > 2 {
                            Text("+\(runner.labels.count - 2)")
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Actions menu
            Menu {
                Button("Remove Runner", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        }
        .padding(16)
        .background(
            Rectangle()
                .fill(isHovered ? Color.primary.opacity(0.02) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
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
            try await apiService.deleteRunner(runnerId: runner.id, from: scope)
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