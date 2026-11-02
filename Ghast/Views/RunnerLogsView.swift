import SwiftUI
import Foundation

struct RunnerLogsView: View {
    let runner: LocalRunner
    @EnvironmentObject private var runnerService: RunnerService
    @State private var tailer: LogTailer?
    @State private var startError: String?
    @State private var isAutoScrollEnabled: Bool = true
    
    /// A failed start replaces the log text until the log changes again.
    private var logText: String {
        startError ?? tailer?.text ?? ""
    }
    
    // Find the current runner from the service to get live status updates
    private var currentRunner: LocalRunner? {
        runnerService.localRunners.first { $0.id == runner.id }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Modern Header with glassmorphism effect
            headerView
            
            // Log content area with terminal-style design
            logContentView
        }
        .background(Color(NSColor.controlBackgroundColor))
        .navigationTitle("")
        .onAppear {
            runnerService.syncRunnerStatus(id: runner.id)
            startTailing()
        }
        .onDisappear {
            let tailer = tailer
            self.tailer = nil
            Task { await tailer?.stop() }
        }
        .onChange(of: tailer?.text) {
            startError = nil
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 0) {
            // Top section with runner info and controls
            HStack(spacing: 16) {
                // Runner info with modern card design
                HStack(spacing: 12) {
                    // Status indicator
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.1))
                            .frame(width: 16, height: 16)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runner.name)
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 6) {
                            Image(systemName: "building.2")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(runner.repository)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Status badge
                statusBadge
                
                // Control buttons with modern design
                controlButtons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.thinMaterial)
            
            // Toolbar with additional controls
            HStack(spacing: 12) {
                // Auto-scroll toggle
                Toggle(isOn: $isAutoScrollEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 11, weight: .medium))
                        Text("Auto-scroll")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                
                Spacer()
                
                // Log file info
                if !logText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("\(logText.components(separatedBy: .newlines).count) lines")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
            
            // Separator
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
        }
    }
    
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(currentRunner?.status.displayName ?? runner.status.displayName)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.08))
        )
    }
    
    private var controlButtons: some View {
        HStack(spacing: 8) {
            if currentRunner?.status == .running {
                Button(action: {
                    runnerService.stopRunner(id: runner.id)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Stop")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.red)
                    )
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    Task {
                        do {
                            try await runnerService.startRunner(id: runner.id)
                            tailer?.reload()
                        } catch {
                            print("Failed to start runner: \(error)")
                            startError = "ERROR: Failed to start runner: \(error.localizedDescription)\n"
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.green)
                    )
                }
                .buttonStyle(.plain)
            }
            
            Button(action: {
                runnerService.clearRunnerLogs(for: runner.id)
                startError = nil
                tailer?.reload()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Clear")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.thinMaterial)
                )
            }
            .buttonStyle(.plain)
        }
    }
    
    private var logContentView: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if logText.isEmpty {
                            // Empty state with modern design
                            VStack(spacing: 16) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 48, weight: .light))
                                    .foregroundColor(.secondary.opacity(0.5))
                                
                                VStack(spacing: 8) {
                                    Text("No logs yet")
                                        .font(.system(.title3, design: .rounded, weight: .semibold))
                                        .foregroundColor(.primary)
                                    
                                    Text("Start the runner to see live output")
                                        .font(.system(.body, design: .rounded))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: geometry.size.height)
                            .frame(minHeight: 300)
                        } else {
                            // Terminal-style log display
                            Text(logText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.clear)
                        }
                        
                        // Scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("logBottom")
                    }
                }
                .background(
                    Rectangle()
                        .fill(Color(NSColor.textBackgroundColor))
                        .overlay(
                            // Terminal-style scanlines effect (subtle)
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.primary.opacity(0.02),
                                            Color.clear,
                                            Color.primary.opacity(0.02)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                )
                .cornerRadius(8)
                .onChange(of: logText) {
                    if isAutoScrollEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo("logBottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }
    
    private var statusColor: Color {
        switch currentRunner?.status ?? runner.status {
        case .stopped: return .gray
        case .running: return .green
        case .error: return .red
        }
    }
    
    private func startTailing() {
        guard tailer == nil else { return }
        let logFileURL = runnerService.getRunnerLogFile(for: runner.id)
        if logFileURL == nil {
            print("❌ Could not get log file URL for runner \(runner.name)")
        }
        let runnerID = runner.id
        let service = runnerService
        let tailer = LogTailer(fileURL: logFileURL) { service.readRunnerLogs(for: runnerID) }
        tailer.start()
        self.tailer = tailer
    }
}

#Preview {
    RunnerLogsView(runner: LocalRunner(
        name: "MacOS Runner",
        repository: "user/sample-repo",
        path: "/Users/user/actions-runner"
    ))
    .environmentObject(RunnerService())
}