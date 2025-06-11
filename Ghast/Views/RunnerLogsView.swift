import SwiftUI
import Combine

struct RunnerLogsView: View {
    let runner: LocalRunner
    @StateObject private var runnerService = RunnerService.shared
    @State private var logText: String = ""
    @State private var refreshTimer: Timer?
    
    // Find the current runner from the service to get live status updates
    private var currentRunner: LocalRunner? {
        runnerService.localRunners.first { $0.id == runner.id }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(runner.name)
                        .font(.headline)
                    Text(runner.repository)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Status indicator - use current runner for live updates
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(currentRunner?.status.displayName ?? runner.status.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Control buttons - use current runner for live updates
                HStack(spacing: 8) {
                    if currentRunner?.status == .running {
                        Button("Stop") {
                            runnerService.stopRunner(id: runner.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Start") {
                            Task {
                                do {
                                    try await runnerService.startRunner(id: runner.id)
                                    // Load logs after starting
                                    loadLogs()
                                } catch {
                                    print("Failed to start runner: \(error)")
                                    logText += "ERROR: Failed to start runner: \(error.localizedDescription)\n"
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    
                    Button("Clear") {
                        runnerService.clearRunnerLogs(for: runner.id)
                        loadLogs()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Log content - selectable text editor
            ScrollViewReader { proxy in
                TextEditor(text: .constant(logText.isEmpty ? "No logs available. Start the runner to see output." : logText))
                    .font(.system(.body, design: .monospaced))
                    .scrollDisabled(false)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        // Hidden anchor for auto-scroll
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .id("logContent")
                            }
                        }
                    )
                    .onChange(of: logText) {
                        // Small delay to ensure TextEditor has updated before scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo("logContent", anchor: .bottom)
                            }
                        }
                    }
            }
        }
        .navigationTitle("Runner Logs")
        .onAppear {
            // Sync runner status to ensure accuracy
            runnerService.syncRunnerStatus(id: runner.id)
            loadLogs()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onReceive(runnerService.$localRunners) { _ in
            // Restart auto-refresh when runner status changes
            stopAutoRefresh()
            if currentRunner?.status == .running {
                startAutoRefresh()
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
    
    private func loadLogs() {
        logText = runnerService.readRunnerLogs(for: runner.id)
    }
    
    private func startAutoRefresh() {
        // Only refresh if runner is running
        guard currentRunner?.status == .running else { return }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                loadLogs()
            }
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

#Preview {
    RunnerLogsView(runner: LocalRunner(
        name: "MacOS Runner",
        repository: "user/sample-repo",
        path: "/Users/user/actions-runner"
    ))
}