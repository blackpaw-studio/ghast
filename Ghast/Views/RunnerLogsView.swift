import SwiftUI
import Combine

struct RunnerLogsView: View {
    let runner: LocalRunner
    @StateObject private var runnerService = RunnerService.shared
    @State private var logText: String = ""
    @State private var refreshTimer: Timer?
    @State private var isAutoScrollEnabled: Bool = true
    
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
            loadLogs()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onReceive(runnerService.$localRunners) { _ in
            stopAutoRefresh()
            if currentRunner?.status == .running {
                startAutoRefresh()
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 0) {
            // Top section with runner info and controls
            HStack(spacing: 16) {
                // Runner info with modern card design
                HStack(spacing: 12) {
                    // Status indicator with glow effect
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.2))
                            .frame(width: 20, height: 20)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
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
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Rectangle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
            
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
                .fill(statusColor.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(statusColor.opacity(0.3), lineWidth: 1)
                )
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
                            loadLogs()
                        } catch {
                            print("Failed to start runner: \(error)")
                            logText = "ERROR: Failed to start runner: \(error.localizedDescription)\n"
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
                loadLogs()
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
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                        )
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
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .onChange(of: logText) { _ in
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