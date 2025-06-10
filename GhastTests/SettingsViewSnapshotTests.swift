import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class SettingsViewSnapshotTests: XCTestCase {
    
    func testSettingsViewAuthenticated() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: GitHubUser(
            id: 1,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        ))
        
        let view = SettingsView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 600, height: 500)
    }
    
    func testSettingsViewNotAuthenticated() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = SettingsView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 600, height: 500)
    }
    
    func testSettingsViewLongUserName() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: GitHubUser(
            id: 1,
            login: "very-long-username-that-might-be-truncated",
            avatarURL: "https://example.com/avatar.png",
            name: "Very Long Display Name That Should Be Handled Properly",
            email: "very.long.email.address@example-domain.com"
        ))
        
        let view = SettingsView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 600, height: 500)
    }
    
    func testSettingsViewDarkMode() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: GitHubUser(
            id: 1,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        ))
        
        let view = SettingsView()
            .environmentObject(authService as GitHubAuthService)
            .preferredColorScheme(.dark)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 600, height: 500)
    }
}