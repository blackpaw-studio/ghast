import SwiftUI
import Combine
import Foundation

struct RunnerLogsView: View {
    let runner: LocalRunner
    @StateObject private var runnerService = RunnerService.shared
    @State private var logText: String = ""
    @State private var refreshTimer: Timer?
    @State private var isAutoScrollEnabled: Bool = true
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var logFileDescriptor: Int32 = -1
    
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
            startFileMonitoring()
        }
        .onDisappear {
            stopAutoRefresh()
            stopFileMonitoring()
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
            .background(
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(
                        Rectangle()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
                .fill(statusColor.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(statusColor.opacity(0.2), lineWidth: 1)
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
                            // File monitoring will automatically pick up changes
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
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
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
    
    private func loadLogs() {
        let newLogs = runnerService.readRunnerLogs(for: runner.id)
        if newLogs != logText {
            print("📝 Log update detected for runner \(runner.name)")
            logText = newLogs
        }
    }
    
    private func startAutoRefresh() {
        // Don't start if already running
        guard refreshTimer == nil else { return }
        
        print("🔄 Starting auto-refresh timer for runner \(runner.name)")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                self.loadLogs()
            }
        }
    }
    
    private func stopAutoRefresh() {
        if refreshTimer != nil {
            print("⏹️ Stopping auto-refresh timer for runner \(runner.name)")
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    private func startFileMonitoring() {
        guard let logFileURL = runnerService.getRunnerLogFile(for: runner.id) else {
            print("❌ Could not get log file URL for runner \(runner.name)")
            return
        }
        
        let logPath = logFileURL.path
        print("📁 Starting file monitoring for: \(logPath)")
        
        // Create the log file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        
        // Open file descriptor for monitoring
        logFileDescriptor = open(logPath, O_RDONLY)
        guard logFileDescriptor >= 0 else {
            print("❌ Could not open log file: \(logPath)")
            return
        }
        
        // Create dispatch source to monitor file changes
        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: logFileDescriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        fileMonitor?.setEventHandler {
            DispatchQueue.main.async {
                loadLogs()
            }
        }
        
        fileMonitor?.setCancelHandler {
            if logFileDescriptor >= 0 {
                close(logFileDescriptor)
                logFileDescriptor = -1
            }
        }
        
        fileMonitor?.resume()
        print("✅ File monitoring started for runner \(runner.name)")
    }
    
    private func stopFileMonitoring() {
        print("🛑 Stopping file monitoring for runner \(runner.name)")
        fileMonitor?.cancel()
        fileMonitor = nil
        
        if logFileDescriptor >= 0 {
            close(logFileDescriptor)
            logFileDescriptor = -1
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