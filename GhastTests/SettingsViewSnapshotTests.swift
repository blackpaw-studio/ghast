import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class SettingsViewSnapshotTests: XCTestCase {
    
    func testSettingsViewAuthenticated() async {
        let authService = GitHubAuthService()
        authService.currentUser = GitHubUser(
            id: 1,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
        
        let view = SettingsView()
            .environmentObject(authService)
            .frame(width: 600, height: 500)
        
        assertSnapshot(of: view, as: Snapshotting.image)
    }
    
    func testSettingsViewNotAuthenticated() async {
        let authService = GitHubAuthService()
        // User not authenticated
        
        let view = SettingsView()
            .environmentObject(authService)
            .frame(width: 600, height: 500)
        
        assertSnapshot(of: view, as: Snapshotting.image)
    }
    
    func testSettingsViewLongUserName() async {
        let authService = GitHubAuthService()
        authService.currentUser = GitHubUser(
            id: 1,
            login: "very-long-username-that-might-be-truncated",
            avatarURL: "https://example.com/avatar.png",
            name: "Very Long Display Name That Should Be Handled Properly",
            email: "very.long.email.address@example-domain.com"
        )
        
        let view = SettingsView()
            .environmentObject(authService)
            .frame(width: 600, height: 500)
        
        assertSnapshot(of: view, as: Snapshotting.image)
    }
    
    func testSettingsViewDarkMode() async {
        let authService = GitHubAuthService()
        authService.currentUser = GitHubUser(
            id: 1,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
        
        let view = SettingsView()
            .environmentObject(authService)
            .frame(width: 600, height: 500)
            .preferredColorScheme(.dark)
        
        assertSnapshot(of: view, as: Snapshotting.image)
    }
}