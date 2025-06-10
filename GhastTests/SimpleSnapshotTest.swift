import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class SimpleSnapshotTest: XCTestCase {
    
    func testStatCard() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue
        )
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
}