import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class DashboardViewSnapshotTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        isRecording = false
    }
    
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
        let authService = GitHubAuthService()
        authService.currentUser = createMockUser()
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        
        let view = DashboardView()
            .environmentObject(authService)
            .environmentObject(appState)
            .frame(width: 1200, height: 800)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardEmpty() async {
        let authService = GitHubAuthService()
        authService.currentUser = createMockUser()
        
        let appState = AppState()
        appState.repositories = []
        
        let view = DashboardView()
            .environmentObject(authService)
            .environmentObject(appState)
            .frame(width: 1200, height: 800)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardLoading() async {
        let authService = GitHubAuthService()
        authService.currentUser = createMockUser()
        
        let appState = AppState()
        appState.isLoadingRepositories = true
        
        let view = DashboardView()
            .environmentObject(authService)
            .environmentObject(appState)
            .frame(width: 1200, height: 800)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardSmallWindow() async {
        let authService = GitHubAuthService()
        authService.currentUser = createMockUser()
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        
        let view = DashboardView()
            .environmentObject(authService)
            .environmentObject(appState)
            .frame(width: 800, height: 600)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardLargeWindow() async {
        let authService = GitHubAuthService()
        authService.currentUser = createMockUser()
        
        let appState = AppState()
        appState.repositories = createMockRepositories()
        
        let view = DashboardView()
            .environmentObject(authService)
            .environmentObject(appState)
            .frame(width: 1600, height: 1000)
        
        assertSnapshot(of: view, as: .image)
    }
}