import SwiftUI

struct LocalRunnersView: View {
    @StateObject private var runnerService = RunnerService.shared
    @State private var selectedRunner: LocalRunner?
    
    var body: some View {
        NavigationSplitView {
            // Sidebar with runner list
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Local Runners")
                        .font(.headline)
                    Spacer()
                    Text("\(runnerService.localRunners.count)")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // Runner list
                if runnerService.localRunners.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text("No Local Runners")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("Create runners from repository detail views to manage them here.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(runnerService.localRunners, selection: $selectedRunner) { runner in
                        LocalRunnerRowView(runner: runner)
                            .tag(runner)
                    }
                }
            }
        } detail: {
            // Detail view
            if let runner = selectedRunner {
                RunnerLogsView(runner: runner)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("Select a Runner")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Choose a local runner from the sidebar to view its logs and manage it.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Local Runners")
    }
}

struct LocalRunnerRowView: View {
    let runner: LocalRunner
    @StateObject private var runnerService = RunnerService.shared
    @State private var showingDeleteAlert = false
    
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
                    
                    Spacer()
                    
                    // Control buttons
                    HStack(spacing: 4) {
                        if runner.status == .running {
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
                
                Text(runner.repository)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    Text(runner.status.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.2))
                        .foregroundColor(statusColor)
                        .clipShape(Capsule())
                    
                    if !runner.labels.isEmpty {
                        ForEach(runner.labels.prefix(2)) { label in
                            Text(label)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .clipShape(Capsule())
                        }
                        
                        if runner.labels.count > 2 {
                            Text("+\(runner.labels.count - 2)")
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
        switch runner.status {
        case .stopped: return .gray
        case .running: return .green
        case .error: return .red
        }
    }
}

extension Array where Element == String {
    fileprivate func prefix(_ maxLength: Int) -> [String] {
        return Array(prefix(maxLength))
    }
}

#Preview {
    LocalRunnersView()
}