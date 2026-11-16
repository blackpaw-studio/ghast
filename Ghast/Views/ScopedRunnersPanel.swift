import SwiftUI

/// The runner page shared by repositories and organizations: a caller-supplied header,
/// runner stats, local runners for `scope`, remote runners not matched by a local one
/// (by name), removal, and the Add Runner sheet.
struct ScopedRunnersPanel<Header: View>: View {
    let scope: RunnerScope
    /// Passed to `AddRunnerView` for its public/private icon.
    var repository: GitHubRepository? = nil
    /// Builds the header; call the closure to open Add Runner.
    @ViewBuilder let header: (_ addRunner: @escaping () -> Void) -> Header

    @State private var runners: [GitHubRunner] = []
    @State private var isLoadingRunners = false
    @State private var showingAddRunner = false
    @State private var errorMessage: String?
    @Environment(RunnerService.self) private var runnerService
    @Environment(\.gitHubAPIService) private var apiService
    
    // Local runners for this scope
    private var localRunners: [LocalRunner] {
        runnerService.localRunners.filter { $0.scope == scope }
    }
    
    // Remote runners excluding those that have local counterparts
    private var filteredRemoteRunners: [GitHubRunner] {
        let localRunnerNames = Set(localRunners.map { $0.name })
        return runners.filter { !localRunnerNames.contains($0.name) }
    }

    private var scopeNoun: String { scope.isOrganization ? "organization" : "repository" }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    // Modern header
                    header { showingAddRunner = true }
                    
                    // Stats overview
                    statsOverview
                    
                    // Runners content
                    modernRunnersContent
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
        }
        .navigationTitle("")
        .sheet(isPresented: $showingAddRunner) {
            AddRunnerView(scope: scope, repository: repository) {
                Task {
                    await loadRunners()
                }
            }
        }
        .task(id: scope) {
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
    
    private var statsOverview: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            ModernStatCard(
                title: "Total Runners",
                value: "\(runners.count + localRunners.count)",
                icon: "server.rack",
                color: .blue,
                isLoading: isLoadingRunners,
                onTap: nil
            )
            
            ModernStatCard(
                title: "Remote Runners",
                value: "\(filteredRemoteRunners.count)",
                icon: "cloud.fill",
                color: .green,
                isLoading: isLoadingRunners,
                onTap: nil
            )
            
            ModernStatCard(
                title: "Local Runners",
                value: "\(localRunners.count)",
                icon: "desktopcomputer",
                color: .purple,
                isLoading: false,
                onTap: nil
            )
        }
        .padding(.horizontal, 24)
    }
    
    private var modernRunnersContent: some View {
        VStack(spacing: 24) {
            // Local runners section
            if !localRunners.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.purple)
                        
                        Text("Local Runners")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Text("\(localRunners.count)")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.1))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    
                    VStack(spacing: 8) {
                        ForEach(localRunners) { runner in
                            ModernLocalRunnerCard(runner: runner)
                        }
                    }
                }
                .padding(20)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
            }
            
            // Remote runners section
            if !filteredRemoteRunners.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.green)
                        
                        Text("Remote Runners")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Text("\(filteredRemoteRunners.count)")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.green.opacity(0.1))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    
                    VStack(spacing: 8) {
                        ForEach(filteredRemoteRunners) { runner in
                            ModernRemoteRunnerCard(runner: runner, scope: scope) {
                                Task {
                                    await loadRunners()
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .stroke(Color.green.opacity(0.2), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
            }
            
            // Empty state
            if localRunners.isEmpty && filteredRemoteRunners.isEmpty && !isLoadingRunners {
                modernEmptyState
            }
            
            // Loading state
            if isLoadingRunners {
                modernLoadingState
            }
        }
    }
    
    private var modernEmptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "server.rack")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.blue.opacity(0.7))
            }
            
            VStack(spacing: 12) {
                Text("No Runners Found")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("Get started by adding your first self-hosted runner for this \(scopeNoun).")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Button(action: { showingAddRunner = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Add Runner")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
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
    
    private var modernLoadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text("Loading runners...")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
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
    
    private func loadRunners() async {
        isLoadingRunners = true
        do {
            let fetchedRunners = try await apiService.fetchRunners(in: scope)
            await MainActor.run {
                self.runners = fetchedRunners
                self.isLoadingRunners = false
                self.errorMessage = nil
            }
        } catch {
            // A view that disappears mid-fetch cancels the request; that isn't a failure.
            let message = error.isCancellation ? nil : scope.errorMessage(for: error)
            await MainActor.run {
                self.isLoadingRunners = false
                if let message { self.errorMessage = message }
            }
        }
    }
}

/// The gradient "Add Runner" capsule shown in runner page headers.
struct AddRunnerHeaderButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Add Runner")
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}
