import XCTest
import SwiftUI
import AppKit
import SnapshotTesting

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
        record: Bool? = nil,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        // Create a container view that provides the sizing context without hard framing
        let containerView = view
            .frame(maxWidth: width, maxHeight: height)
            .background(Color.clear)
        
        // Wrap SwiftUI view in NSHostingController for macOS snapshot testing
        let hostingController = NSHostingController(rootView: containerView)
        
        // Set the hosting controller's view frame for consistent snapshot sizing
        hostingController.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        
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
    
    /// Creates a snapshot of a SwiftUI view with natural sizing within a container
    /// Useful for views that need more space or have complex layouts
    static func assertSnapshotNaturalSize<V: View>(
        of view: V,
        containerWidth: CGFloat = 1200,
        containerHeight: CGFloat = 800,
        record: Bool? = nil,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        // Create a container that allows the view to size naturally within bounds
        let containerView = view
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