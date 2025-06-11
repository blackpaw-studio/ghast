import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class RunnerLogsViewSnapshotTests: XCTestCase {
    
    // Set to true to record new snapshots, false to compare against existing
    private let isRecording = false
    
    private func createMockRunner(status: RunnerStatus = .stopped) -> LocalRunner {
        LocalRunner(
            name: "Test Runner",
            repository: "evandcoleman/ghast",
            path: "/Users/test/.ghast/runners/test-runner"
        )
    }
    
    func testRunnerLogsViewEmpty() async {
        let runner = createMockRunner()
        
        let view = RunnerLogsView(runner: runner)
            .frame(width: 900, height: 600)
        
        SnapshotTestHelpers.assertSnapshot(
            of: view,
            width: 900,
            height: 600,
            record: isRecording
        )
    }
    
    func testRunnerLogsViewWithLogs() async {
        let runner = createMockRunner(status: .running)
        
        // Create a temporary log file with sample content
        let tempDir = NSTemporaryDirectory()
        let logFile = URL(fileURLWithPath: tempDir).appendingPathComponent("test-runner.log")
        let sampleLogs = """
        13:26:41 🏃 Starting runner 'Test Runner'
        13:26:42 🚀 Executing ./run.sh
        13:26:42 √ Connected to GitHub
        13:26:42 
        13:26:42 Current runner version: '2.325.0'
        13:26:42 2025-06-11 17:26:42Z: Listening for Jobs
        13:26:45 2025-06-11 17:26:45Z: Running job: Build and Test
        13:26:46 2025-06-11 17:26:46Z: Job completed with result: Succeeded
        13:26:47 🏁 Runner exited with code 0
        13:26:52 🔄 Restarting runner in 5 seconds...
        13:26:57 🚀 Executing ./run.sh
        13:26:58 √ Connected to GitHub
        """
        
        try? sampleLogs.write(to: logFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: logFile) }
        
        let view = RunnerLogsView(runner: runner)
            .frame(width: 900, height: 600)
        
        SnapshotTestHelpers.assertSnapshot(
            of: view,
            width: 900,
            height: 600,
            record: isRecording
        )
    }
    
    func testRunnerLogsViewRunningState() async {
        let runner = createMockRunner(status: .running)
        
        let view = RunnerLogsView(runner: runner)
            .frame(width: 900, height: 600)
        
        SnapshotTestHelpers.assertSnapshot(
            of: view,
            width: 900,
            height: 600,
            record: isRecording
        )
    }
    
    func testRunnerLogsViewErrorState() async {
        let runner = createMockRunner(status: .error)
        
        let view = RunnerLogsView(runner: runner)
            .frame(width: 900, height: 600)
        
        SnapshotTestHelpers.assertSnapshot(
            of: view,
            width: 900,
            height: 600,
            record: isRecording
        )
    }
    
    func testRunnerLogsViewSmallWindow() async {
        let runner = createMockRunner()
        
        let view = RunnerLogsView(runner: runner)
            .frame(width: 600, height: 400)
        
        SnapshotTestHelpers.assertSnapshot(
            of: view,
            width: 600,
            height: 400,
            record: isRecording
        )
    }
    
    func testRunnerLogsViewLargeWindow() async {
        let runner = createMockRunner()
        
        let view = RunnerLogsView(runner: runner)
            .frame(width: 1200, height: 800)
        
        SnapshotTestHelpers.assertSnapshot(
            of: view,
            width: 1200,
            height: 800,
            record: isRecording
        )
    }
}