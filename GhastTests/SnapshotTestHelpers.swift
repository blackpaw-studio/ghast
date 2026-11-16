import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Ghast

/// Helper functions for snapshot testing SwiftUI views on macOS
@MainActor
enum SnapshotTestHelpers {
    
    /// Check if snapshot recording is enabled via environment variable
    static var isRecordingSnapshots: Bool {
        return ProcessInfo.processInfo.environment["SNAPSHOT_RECORD_MODE"] == "true"
    }
    
    /// Creates a snapshot of a SwiftUI view with specified dimensions using NSHostingController
    /// This helper resolves type ambiguity issues with SnapshotTesting framework on macOS
    static func assertSnapshot<V: View>(
        of view: V,
        width: CGFloat,
        height: CGFloat,
        runnerService: RunnerService? = nil,
        record: Bool? = nil,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let hostingController = makeHostingController(of: view, width: width, height: height, runnerService: runnerService)
        assertImage(of: hostingController, record: record, file: file, testName: testName, line: line)
    }
    
    /// Like `assertSnapshot`, but first lets the view's `.task` work finish against
    /// immediately-returning mocks, so the image shows loaded data rather than a spinner.
    /// Only yields; never sleeps.
    static func assertSettledSnapshot<V: View>(
        of view: V,
        width: CGFloat,
        height: CGFloat,
        runnerService: RunnerService? = nil,
        record: Bool? = nil,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) async {
        let hostingController = makeHostingController(of: view, width: width, height: height, runnerService: runnerService)
        for _ in 0..<settlePasses {
            await Task.yield()
        }
        hostingController.view.layoutSubtreeIfNeeded()
        assertImage(of: hostingController, record: record, file: file, testName: testName, line: line)
    }
    
    private static let settlePasses = 20
    
    private static func makeHostingController<V: View>(
        of view: V,
        width: CGFloat,
        height: CGFloat,
        runnerService: RunnerService?
    ) -> NSViewController {
        // Create a container view that provides the sizing context without hard framing
        let containerView = view
            .environment(runnerService ?? makeTestRunnerService())
            .environment(\.gitHubAPIService, MockGitHubAPIService())
            .frame(maxWidth: width, maxHeight: height)
            .background(Color.clear)
        
        // Wrap SwiftUI view in NSHostingController for macOS snapshot testing
        let hostingController = NSHostingController(rootView: containerView)
        
        // Set the hosting controller's view frame for consistent snapshot sizing
        hostingController.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        
        // Force layout to ensure proper sizing
        hostingController.view.layoutSubtreeIfNeeded()
        return hostingController
    }
    
    private static func assertImage(
        of hostingController: NSViewController,
        record: Bool?,
        file: StaticString,
        testName: String,
        line: UInt
    ) {
        // Use environment variable if record parameter is not explicitly set
        let shouldRecord = isRecordingSnapshots || (record ?? false)
        
        // Use record parameter or withSnapshotTesting to record snapshots
        if shouldRecord {
            withSnapshotTesting(record: .all) {
                SnapshotTesting.assertSnapshot(
                    of: hostingController,
                    as: .image,
                    file: file,
                    testName: testName,
                    line: line
                )
            }
        } else {
            // Use explicit function call to resolve ambiguity
            SnapshotTesting.assertSnapshot(
                of: hostingController,
                as: .image,
                file: file,
                testName: testName,
                line: line
            )
        }
    }
    
    /// Creates a snapshot of a SwiftUI view with natural sizing within a container
    /// Useful for views that need more space or have complex layouts
    static func assertSnapshotNaturalSize<V: View>(
        of view: V,
        containerWidth: CGFloat = 1200,
        containerHeight: CGFloat = 800,
        runnerService: RunnerService? = nil,
        record: Bool? = nil,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        // Create a container that allows the view to size naturally within bounds
        let containerView = view
            .environment(runnerService ?? makeTestRunnerService())
            .environment(\.gitHubAPIService, MockGitHubAPIService())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: containerWidth, height: containerHeight)
            .background(Color.clear)
        
        // Wrap SwiftUI view in NSHostingController for macOS snapshot testing
        let hostingController = NSHostingController(rootView: containerView)
        
        // Set the hosting controller's view frame
        hostingController.view.frame = CGRect(origin: .zero, size: CGSize(width: containerWidth, height: containerHeight))
        
        // Force layout to ensure proper sizing
        hostingController.view.layoutSubtreeIfNeeded()
        
        // Use environment variable if record parameter is not explicitly set
        let shouldRecord = isRecordingSnapshots || (record ?? false)
        
        // Use record parameter or withSnapshotTesting to record snapshots
        if shouldRecord {
            withSnapshotTesting(record: .all) {
                SnapshotTesting.assertSnapshot(
                    of: hostingController,
                    as: .image,
                    file: file,
                    testName: testName,
                    line: line
                )
            }
        } else {
            // Use explicit function call to resolve ambiguity
            SnapshotTesting.assertSnapshot(
                of: hostingController,
                as: .image,
                file: file,
                testName: testName,
                line: line
            )
        }
    }
}