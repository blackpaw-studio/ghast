import SwiftUI
import Combine

struct RunnerLogsView: View {
    let runner: LocalRunner
    @StateObject private var runnerService = RunnerService.shared
    @State private var logText: String = ""
    @State private var cancellable: AnyCancellable?
    
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
                                    // Setup log stream after starting
                                    setupLogStream()
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
                        logText = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText.isEmpty ? "No logs available. Start the runner to see output." : logText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                        .id("logContent")
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: logText) {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("logContent", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Runner Logs")
        .onAppear {
            // Sync runner status to ensure accuracy
            runnerService.syncRunnerStatus(id: runner.id)
            setupLogStream()
        }
        .onDisappear {
            cancellable?.cancel()
        }
        .onReceive(runnerService.$localRunners) { _ in
            // Re-setup log stream when runners change (e.g., when status updates)
            setupLogStream()
        }
    }
    
    private var statusColor: Color {
        switch currentRunner?.status ?? runner.status {
        case .stopped: return .gray
        case .running: return .green
        case .error: return .red
        }
    }
    
    private func setupLogStream() {
        // Cancel any existing subscription
        cancellable?.cancel()
        
        // Try to get the log stream
        if let logStream = runnerService.getLogStream(for: runner.id) {
            cancellable = logStream
                .receive(on: DispatchQueue.main)
                .sink { logLine in
                    logText += logLine
                }
            print("🏃 Log stream setup for runner: \(runner.name)")
        } else {
            print("🏃 No log stream available for runner: \(runner.name)")
            
            // If no stream exists and runner is running, try to reconnect in a moment
            if currentRunner?.status == .running {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    setupLogStream()
                }
            }
        }
    }
}

#Preview {
    RunnerLogsView(runner: LocalRunner(
        name: "MacOS Runner",
        repository: "user/sample-repo",
        path: "/Users/user/actions-runner"
    ))
}