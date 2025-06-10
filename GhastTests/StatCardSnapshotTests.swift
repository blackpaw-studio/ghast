import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class StatCardSnapshotTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        isRecording = false
    }
    
    func testStatCardDefault() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue
        )
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testStatCardWithLongTitle() async {
        let view = StatCard(
            title: "Very Long Title That Might Wrap",
            value: "42",
            icon: "text.alignleft",
            color: .purple
        )
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testStatCardWithLargeValue() async {
        let view = StatCard(
            title: "Active Runners",
            value: "999,999",
            icon: "checkmark.circle.fill",
            color: .green
        )
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testStatCardZero() async {
        let view = StatCard(
            title: "Busy Runners",
            value: "0",
            icon: "exclamationmark.circle.fill",
            color: .orange
        )
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testStatCardLoading() async {
        let view = StatCard(
            title: "Repositories",
            value: "–",
            icon: "folder.fill",
            color: .purple,
            isLoading: true
        )
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: .image)
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
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testStatCardDarkMode() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue
        )
        .frame(width: 200, height: 120)
        .preferredColorScheme(.dark)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testStatCardsGrid() async {
        let cards = HStack(spacing: 16) {
            StatCard(title: "Total", value: "12", icon: "play.circle.fill", color: .blue)
            StatCard(title: "Online", value: "8", icon: "checkmark.circle.fill", color: .green)
            StatCard(title: "Busy", value: "3", icon: "exclamationmark.circle.fill", color: .orange)
            StatCard(title: "Repos", value: "25", icon: "folder.fill", color: .purple)
        }
        .frame(width: 900, height: 120)
        
        assertSnapshot(of: cards, as: .image)
    }
}