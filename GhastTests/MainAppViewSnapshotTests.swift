import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class MainAppViewSnapshotTests: XCTestCase {
    
    // Set to true to record new snapshots, false to compare against existing
    private let isRecording = false
    
    private func createMockUser() -> GitHubUser {
        GitHubUser(
            id: 1,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
    }
    
    private func createMockRepositories() -> [GitHubRepository] {
        let user = createMockUser()
        return [
            GitHubRepository(
                id: 1,
                name: "ghast",
                fullName: "testuser/ghast",
                description: "A macOS app for managing GitHub Actions self-hosted runners",
                isPrivate: false,
                owner: user,
                htmlURL: "https://github.com/testuser/ghast"
            ),
            GitHubRepository(
                id: 2,
                name: "private-project",
                fullName: "testuser/private-project",
                description: "A private repository with workflows",
                isPrivate: true,
                owner: user,
                htmlURL: "https://github.com/testuser/private-project"
            )
        ]
    }
    
    func testMainAppViewWithDashboard() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        appState.selectedView = .dashboard
        
        let mockAPIService = MockGitHubAPIService()
        mockAPIService.mockRunners = []
        
        let view = MainAppView()
            .environmentObject(authService as GitHubAuthService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: isRecording)
    }
    
    func testMainAppViewEmpty() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = []
        appState.selectedView = .dashboard
        
        let mockAPIService = MockGitHubAPIService()
        mockAPIService.mockRunners = []
        
        let view = MainAppView()
            .environmentObject(authService as GitHubAuthService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: isRecording)
    }
    
    func testMainAppViewLocalRunners() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        appState.selectedView = .localRunners
        
        let mockAPIService = MockGitHubAPIService()
        mockAPIService.mockRunners = []
        
        let view = MainAppView()
            .environmentObject(authService as GitHubAuthService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: isRecording)
    }
    
    func testMainAppViewSettings() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        appState.selectedView = .settings
        
        let mockAPIService = MockGitHubAPIService()
        mockAPIService.mockRunners = []
        
        let view = MainAppView()
            .environmentObject(authService as GitHubAuthService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: isRecording)
    }
    
    func testMainAppViewSmallWindow() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        appState.selectedView = .dashboard
        
        let mockAPIService = MockGitHubAPIService()
        mockAPIService.mockRunners = []
        
        let view = MainAppView()
            .environmentObject(authService as GitHubAuthService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600, record: isRecording)
    }
    
    func testMainAppViewLargeWindow() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        appState.selectedView = .dashboard
        
        let mockAPIService = MockGitHubAPIService()
        mockAPIService.mockRunners = []
        
        let view = MainAppView()
            .environmentObject(authService as GitHubAuthService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1600, height: 1000, record: isRecording)
    }
}