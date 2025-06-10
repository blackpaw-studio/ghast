import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class StatCardSnapshotTests: XCTestCase {
    
    func testStatCardDefault() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue
        )
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
    
    func testStatCardWithLongTitle() async {
        let view = StatCard(
            title: "Very Long Title That Might Wrap",
            value: "42",
            icon: "text.alignleft",
            color: .purple
        )
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
    
    func testStatCardWithLargeValue() async {
        let view = StatCard(
            title: "Active Runners",
            value: "999,999",
            icon: "checkmark.circle.fill",
            color: .green
        )
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
    
    func testStatCardZero() async {
        let view = StatCard(
            title: "Busy Runners",
            value: "0",
            icon: "exclamationmark.circle.fill",
            color: .orange
        )
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
    
    func testStatCardLoading() async {
        let view = StatCard(
            title: "Repositories",
            value: "–",
            icon: "folder.fill",
            color: .purple,
            isLoading: true
        )
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
    
    func testStatCardClickable() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue,
            onTap: {
                // Action handler
            }
        )
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
    
    func testStatCardDarkMode() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue
        )
        .preferredColorScheme(.dark)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 120)
    }
    
    func testStatCardsGrid() async {
        let cards = HStack(spacing: 16) {
            StatCard(title: "Total", value: "12", icon: "play.circle.fill", color: .blue)
            StatCard(title: "Online", value: "8", icon: "checkmark.circle.fill", color: .green)
            StatCard(title: "Busy", value: "3", icon: "exclamationmark.circle.fill", color: .orange)
            StatCard(title: "Repos", value: "25", icon: "folder.fill", color: .purple)
        }
        
        SnapshotTestHelpers.assertSnapshot(of: cards, width: 900, height: 120)
    }
}