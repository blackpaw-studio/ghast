import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class SimpleSnapshotTest: XCTestCase {
    
    override func setUp() {
        super.setUp()
        isRecording = false
    }
    
    func testStatCard() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue
        )
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
}