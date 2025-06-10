import XCTest
import SwiftUI
import AppKit
import SnapshotTesting

/// Helper functions for snapshot testing SwiftUI views on macOS
@MainActor
enum SnapshotTestHelpers {
    
    /// Creates a snapshot of a SwiftUI view with specified dimensions using NSHostingController
    /// This helper resolves type ambiguity issues with SnapshotTesting framework on macOS
    static func assertSnapshot<V: View>(
        of view: V,
        width: CGFloat,
        height: CGFloat,
        record: Bool = false,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        // Frame the view to the specified dimensions
        let framedView = view.frame(width: width, height: height)
        
        // Wrap SwiftUI view in NSHostingController for macOS snapshot testing
        let hostingController = NSHostingController(rootView: framedView)
        hostingController.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        
        // Use record parameter or withSnapshotTesting to record snapshots
        if record {
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