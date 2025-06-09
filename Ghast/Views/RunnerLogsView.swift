import SwiftUI
import Combine

struct RunnerLogsView: View {
    let runner: LocalRunner
    @StateObject private var runnerService = RunnerService.shared
    @State private var logText: String = ""
    @State private var cancellable: AnyCancellable?
    
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
                
                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(runner.status.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Control buttons
                HStack(spacing: 8) {
                    if runner.status == .running {
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
                                } catch {
                                    print("Failed to start runner: \(error)")
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
                .onChange(of: logText) { _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("logContent", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Runner Logs")
        .onAppear {
            setupLogStream()
        }
        .onDisappear {
            cancellable?.cancel()
        }
    }
    
    private var statusColor: Color {
        switch runner.status {
        case .stopped: return .gray
        case .running: return .green
        case .error: return .red
        }
    }
    
    private func setupLogStream() {
        cancellable = runnerService.getLogStream(for: runner.id)?
            .receive(on: DispatchQueue.main)
            .sink { logLine in
                logText += logLine
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