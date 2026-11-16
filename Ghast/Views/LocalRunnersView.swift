import SwiftUI

struct LocalRunnersView: View {
    @Environment(RunnerService.self) private var runnerService
    @Environment(AppState.self) private var appState
    @State private var selectedRunner: LocalRunner?
    @State private var showingNewRunnerFlow = false
    
    var body: some View {
        HStack(spacing: 0) {
            // Modern Sidebar with runner list
            VStack(spacing: 0) {
                // Header with glassmorphism design
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Local Runners")
                                .font(.system(.title2, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                            
                            Text("Manage your self-hosted runners")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 12) {
                            // Refresh/discover button
                            Button(action: {
                                runnerService.scanForExistingRunners()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.blue)
                                    Text("Refresh")
                                        .font(.system(.caption, design: .rounded, weight: .medium))
                                        .foregroundStyle(.blue)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.blue.opacity(0.08))
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Discover existing runners and refresh list")
                            
                            // Runner count badge
                            HStack(spacing: 6) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.blue)
                                Text("\(runnerService.localRunners.count)")
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.blue.opacity(0.08))
                            )
                        }
                    }
                    
                    // Action button
                    Button(action: {
                        showingNewRunnerFlow = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("New Runner")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: Color.blue.opacity(0.3), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.repositories.isEmpty)
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
                
                // Separator
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
                
                // Runner list with modern design
                if runnerService.localRunners.isEmpty {
                    modernEmptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(runnerService.localRunners) { runner in
                                ModernRunnerCard(
                                    runner: runner,
                                    isSelected: selectedRunner?.id == runner.id
                                ) {
                                    selectedRunner = runner
                                }
                            }
                        }
                        .padding(16)
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 450)
            
            // Separator
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)
            
            // Detail view
            Group {
                if let runner = selectedRunner {
                    RunnerLogsView(runner: runner)
                } else {
                    modernSelectionState
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 800, idealWidth: 1000, maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .navigationTitle("")
        .sheet(isPresented: $showingNewRunnerFlow) {
            NewRunnerFlowView(repositories: appState.repositories)
        }
    }
    
    private var modernEmptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "server.rack")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.blue)
            }
            
            VStack(spacing: 12) {
                Text("No Local Runners")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("Create runners from repository detail views to manage them here. Runners let you execute GitHub Actions workflows on your own hardware.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            
            Button("Get Started") {
                showingNewRunnerFlow = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.repositories.isEmpty)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var modernSelectionState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.purple)
            }
            
            VStack(spacing: 12) {
                Text("Select a Runner")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("Choose a local runner from the sidebar to view its logs, monitor status, and manage its lifecycle.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

struct ModernRunnerCard: View {
    let runner: LocalRunner
    let isSelected: Bool
    let onTap: () -> Void
    
    @Environment(RunnerService.self) private var runnerService
    @State private var showingDeleteAlert = false
    @State private var showingConfiguration = false
    @State private var isHovered = false
    
    // Find the current runner from the service to get live status updates
    private var currentRunner: LocalRunner? {
        runnerService.localRunners.first { $0.id == runner.id }
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 16) {
                // Header with status and actions
                HStack(spacing: 12) {
                    // Status indicator with glow effect
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.2))
                            .frame(width: 20, height: 20)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        
                        if currentRunner?.status == .running {
                            Circle()
                                .stroke(statusColor, lineWidth: 1)
                                .frame(width: 16, height: 16)
                                .scaleEffect(isHovered ? 1.2 : 1.0)
                                .opacity(isHovered ? 0.8 : 0.4)
                                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isHovered)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runner.name)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        HStack(spacing: 6) {
                            Image(systemName: "building.2")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            RunnerScopeLabel(scope: runner.scope)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    // More menu
                    Menu {
                        Button("Configure") {
                            showingConfiguration = true
                        }
                        
                        Divider()
                        
                        Button("Remove Runner", role: .destructive) {
                            showingDeleteAlert = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || isSelected ? 1 : 0.6)
                }
                
                // Status badge and labels
                HStack(spacing: 8) {
                    // Status badge
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(currentRunner?.status.displayName ?? runner.status.displayName)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(statusColor.opacity(0.1))
                            .overlay(
                                Capsule()
                                    .stroke(statusColor.opacity(0.3), lineWidth: 1)
                            )
                    )
                    
                    Spacer()
                    
                    // Control button
                    if currentRunner?.status == .running {
                        Button(action: {
                            Task { await runnerService.stopRunner(id: runner.id) }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Stop")
                                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: {
                            Task {
                                do {
                                    try await runnerService.startRunner(id: runner.id)
                                } catch {
                                    print("Failed to start runner: \(error)")
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Start")
                                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // Labels (if any)
                if !runner.labels.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(runner.labels.prefixStrings(3), id: \.self) { label in
                            Text(label)
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                )
                        }
                        
                        if runner.labels.count > 3 {
                            Text("+\(runner.labels.count - 3)")
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                }
            }
            .padding(16)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Rectangle()
                            .stroke(strokeColor, lineWidth: strokeWidth)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .alert("Remove Runner", isPresented: $showingDeleteAlert) {
            Button("Remove", role: .destructive) {
                runnerService.removeLocalRunner(id: runner.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to remove '\(runner.name)'? This will stop the runner if it's running.")
        }
        .sheet(isPresented: $showingConfiguration) {
            RunnerConfigurationView(runner: runner)
        }
    }
    
    private var strokeColor: Color {
        if isSelected {
            return Color.blue.opacity(0.5)
        } else if isHovered {
            return Color.primary.opacity(0.2)
        } else {
            return Color.primary.opacity(0.1)
        }
    }
    
    private var strokeWidth: CGFloat {
        isSelected ? 2 : 1
    }
    
    private var shadowColor: Color {
        if isSelected {
            return Color.blue.opacity(0.2)
        } else if isHovered {
            return Color.black.opacity(0.1)
        } else {
            return Color.clear
        }
    }
    
    private var shadowRadius: CGFloat {
        if isSelected {
            return 8
        } else if isHovered {
            return 4
        } else {
            return 0
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

struct LocalRunnerRowView: View {
    let runner: LocalRunner
    @Environment(RunnerService.self) private var runnerService
    @State private var showingDeleteAlert = false
    
    // Find the current runner from the service to get live status updates
    private var currentRunner: LocalRunner? {
        runnerService.localRunners.first { $0.id == runner.id }
    }
    
    var body: some View {
        ModernRunnerCard(runner: runner, isSelected: false) { }
    }
    
    private var statusColor: Color {
        switch currentRunner?.status ?? runner.status {
        case .stopped: return .gray
        case .running: return .green
        case .error: return .red
        }
    }
}

extension Array where Element == String {
    fileprivate func prefixStrings(_ maxLength: Int) -> [String] {
        return Array(self.prefix(maxLength))
    }
}

#Preview {
    LocalRunnersView()
}