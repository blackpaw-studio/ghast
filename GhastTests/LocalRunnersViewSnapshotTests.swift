import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class LocalRunnersViewSnapshotTests: XCTestCase {
    
    // Set to true to record new snapshots, false to compare against existing
    private let isRecording = false
    
    private func createMockRunners() -> [LocalRunner] {
        let runner1 = LocalRunner(
            name: "production-runner-1",
            repository: "testuser/ghast",
            path: "/Users/test/.ghast/runners/production-runner-1",
            labels: ["self-hosted", "macOS", "ARM64", "production"]
        )
        
        let runner2 = LocalRunner(
            name: "staging-runner",
            repository: "testuser/private-project",
            path: "/Users/test/.ghast/runners/staging-runner",
            labels: ["self-hosted", "staging", "x64"]
        )
        
        let runner3 = LocalRunner(
            name: "test-runner-long-name-to-check-layout",
            repository: "testuser/another-really-long-repository-name",
            path: "/Users/test/.ghast/runners/test-runner",
            labels: ["self-hosted", "test", "linux", "docker", "kubernetes", "ci/cd"]
        )
        
        return [runner1, runner2, runner3]
    }
    
    func testLocalRunnersViewEmpty() async {
        let appState = AppState()
        appState.repositories = [] // Empty repositories
        
        // Clear any existing runners
        let runnerService = RunnerService.shared
        runnerService.localRunners.removeAll()
        
        let view = LocalRunnersView()
            .environmentObject(appState)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: isRecording)
        
        // Clean up
        runnerService.localRunners.removeAll()
    }
    
    func testLocalRunnersViewWithRunners() async {
        let appState = AppState()
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "ghast",
                fullName: "testuser/ghast",
                description: "Test repository",
                isPrivate: false,
                owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: "test@example.com"),
                htmlURL: "https://github.com/testuser/ghast"
            )
        ]
        
        // Add mock runners
        let runnerService = RunnerService.shared
        runnerService.localRunners.removeAll()
        
        let mockRunners = createMockRunners()
        for (index, runner) in mockRunners.enumerated() {
            runnerService.addLocalRunner(runner)
            // Set different statuses for visual variety
            if index == 0 {
                runnerService.localRunners[index].status = .running
            } else if index == 2 {
                runnerService.localRunners[index].status = .error
            }
        }
        
        let view = LocalRunnersView()
            .environmentObject(appState)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: isRecording)
        
        // Clean up
        runnerService.localRunners.removeAll()
    }
    
    func testLocalRunnersViewWithSelectedRunner() async {
        let appState = AppState()
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "ghast",
                fullName: "testuser/ghast",
                description: "Test repository",
                isPrivate: false,
                owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: "test@example.com"),
                htmlURL: "https://github.com/testuser/ghast"
            )
        ]
        
        // Add mock runners
        let runnerService = RunnerService.shared
        runnerService.localRunners.removeAll()
        
        let mockRunners = createMockRunners()
        for runner in mockRunners {
            runnerService.addLocalRunner(runner)
        }
        
        // Set first runner as running
        runnerService.localRunners[0].status = .running
        
        // Create a wrapper view that pre-selects a runner
        struct TestWrapper: View {
            @StateObject private var runnerService = RunnerService.shared
            @EnvironmentObject var appState: AppState
            @State private var selectedRunner: LocalRunner?
            
            var body: some View {
                HStack(spacing: 0) {
                    // Sidebar with runner list
                    VStack(spacing: 0) {
                        // Header
                        VStack(spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Local Runners")
                                        .font(.system(.title2, design: .rounded, weight: .semibold))
                                    Text("Manage your self-hosted runners")
                                        .font(.system(.caption, design: .rounded, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 6) {
                                    Image(systemName: "server.rack")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("\(runnerService.localRunners.count)")
                                        .font(.system(.caption, design: .rounded, weight: .bold))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.blue.opacity(0.1)))
                            }
                            
                            Button(action: {}) {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("New Runner")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(20)
                        
                        Divider()
                        
                        // Runner list
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
                    }
                    .frame(width: 400)
                    
                    Divider()
                    
                    // Detail view with logs
                    if let runner = selectedRunner {
                        RunnerLogsView(runner: runner)
                    }
                }
                .frame(width: 1200, height: 800)
                .onAppear {
                    // Select the first runner
                    selectedRunner = runnerService.localRunners.first
                }
            }
        }
        
        let view = TestWrapper()
            .environmentObject(appState)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: isRecording)
        
        // Clean up
        runnerService.localRunners.removeAll()
    }
    
    func testLocalRunnersViewSmallWindow() async {
        let appState = AppState()
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "ghast",
                fullName: "testuser/ghast",
                description: "Test repository",
                isPrivate: false,
                owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: "test@example.com"),
                htmlURL: "https://github.com/testuser/ghast"
            )
        ]
        
        // Add mock runners
        let runnerService = RunnerService.shared
        runnerService.localRunners.removeAll()
        
        let mockRunners = createMockRunners()
        for runner in mockRunners {
            runnerService.addLocalRunner(runner)
        }
        
        let view = LocalRunnersView()
            .environmentObject(appState)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600, record: isRecording)
        
        // Clean up
        runnerService.localRunners.removeAll()
    }
    
    func testLocalRunnersViewLargeWindow() async {
        let appState = AppState()
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "ghast",
                fullName: "testuser/ghast",
                description: "Test repository",
                isPrivate: false,
                owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: "test@example.com"),
                htmlURL: "https://github.com/testuser/ghast"
            )
        ]
        
        // Add mock runners
        let runnerService = RunnerService.shared
        runnerService.localRunners.removeAll()
        
        let mockRunners = createMockRunners()
        for (index, runner) in mockRunners.enumerated() {
            runnerService.addLocalRunner(runner)
            // Mix of statuses
            if index == 0 {
                runnerService.localRunners[index].status = .running
            } else if index == 2 {
                runnerService.localRunners[index].status = .error
            }
        }
        
        let view = LocalRunnersView()
            .environmentObject(appState)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1600, height: 1000, record: isRecording)
        
        // Clean up
        runnerService.localRunners.removeAll()
    }
}