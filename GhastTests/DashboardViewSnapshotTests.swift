import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class DashboardViewSnapshotTests: XCTestCase {
    
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
    
    func testDashboardWithRepositories() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        
        let mockAPIService = MockGitHubAPIService()
        // Set empty runners to avoid API calls
        mockAPIService.mockRunners = []
        
        let view = DashboardView()
            .environment(authService as GitHubAuthService)
            .environment(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: false)
    }
    
    func testDashboardEmpty() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = []
        
        let mockAPIService = MockGitHubAPIService()
        // Set empty runners to avoid API calls
        mockAPIService.mockRunners = []
        
        let view = DashboardView()
            .environment(authService as GitHubAuthService)
            .environment(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: false)
    }
    
    func testDashboardLoading() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.isLoadingRepositories = true
        
        let mockAPIService = MockGitHubAPIService()
        // Set empty runners to avoid API calls
        mockAPIService.mockRunners = []
        
        let view = DashboardView()
            .environment(authService as GitHubAuthService)
            .environment(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800, record: false)
    }
    
    func testDashboardSmallWindow() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        
        let mockAPIService = MockGitHubAPIService()
        // Set empty runners to avoid API calls
        mockAPIService.mockRunners = []
        
        let view = DashboardView()
            .environment(authService as GitHubAuthService)
            .environment(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600, record: false)
    }
    
    func testDashboardLargeWindow() async {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: createMockUser())
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        
        let mockAPIService = MockGitHubAPIService()
        // Set empty runners to avoid API calls
        mockAPIService.mockRunners = []
        
        let view = DashboardView()
            .environment(authService as GitHubAuthService)
            .environment(appState)
            .environment(\.gitHubAPIService, mockAPIService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1600, height: 1000, record: false)
    }
}