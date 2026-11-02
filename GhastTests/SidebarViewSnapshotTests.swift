import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class SidebarViewSnapshotTests: XCTestCase {
    
    var authService: GitHubAuthService!
    var appState: AppState!
    var mockAPIService: MockGitHubAPIService!
    
    override func setUp() async throws {
        try await super.setUp()
        authService = GitHubAuthService(tokenStore: InMemoryTokenStore())
        appState = AppState()
        mockAPIService = MockGitHubAPIService()
        
        // Set recording mode based on environment variable
        // Note: isRecording is set in individual test files when needed
    }
    
    override func tearDown() async throws {
        authService = nil
        appState = nil
        mockAPIService = nil
        try await super.tearDown()
    }
    
    // MARK: - Empty State Tests
    
    func testSidebarViewEmpty() {
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    // MARK: - Loading State Tests
    
    func testSidebarViewLoading() {
        appState.isLoadingRepositories = true
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    // MARK: - Repository List Tests
    
    func testSidebarViewWithRepositories() {
        // Set up mock repositories
        appState.repositories = createMockRepositories()
        appState.selectedView = .dashboard
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    func testSidebarViewWithSelectedRepository() {
        let repositories = createMockRepositories()
        appState.repositories = repositories
        
        // Select the second repository
        if repositories.count > 1 {
            appState.selectedView = .repository(repositories[1])
            appState.selectedRepository = repositories[1]
        }
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    // MARK: - Navigation State Tests
    
    func testSidebarViewLocalRunnersSelected() {
        appState.repositories = createMockRepositories()
        appState.selectedView = .localRunners
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    func testSidebarViewSettingsSelected() {
        appState.repositories = createMockRepositories()
        appState.selectedView = .settings
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    // MARK: - Search Tests
    
    func testSidebarViewWithSearch() {
        appState.repositories = createMockRepositories()
        
        // Note: We can't directly set the searchText since it's a private @State
        // but we can test the view with repositories that would be filtered
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    // MARK: - Different Repository States Tests
    
    func testSidebarViewPrivateRepositories() {
        // All private repositories
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "private-api",
                fullName: "testuser/private-api",
                description: "Private API implementation",
                isPrivate: true,
                owner: createMockUser(),
                htmlURL: "https://github.com/testuser/private-api"
            ),
            GitHubRepository(
                id: 2,
                name: "secret-project",
                fullName: "testuser/secret-project",
                description: "Top secret project",
                isPrivate: true,
                owner: createMockUser(),
                htmlURL: "https://github.com/testuser/secret-project"
            )
        ]
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    func testSidebarViewLongRepositoryNames() {
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "very-long-repository-name-that-should-be-truncated",
                fullName: "testuser/very-long-repository-name-that-should-be-truncated",
                description: "This repository has an extremely long name that will need to be truncated in the UI",
                isPrivate: false,
                owner: createMockUser(),
                htmlURL: "https://github.com/testuser/very-long-repository-name"
            ),
            GitHubRepository(
                id: 2,
                name: "another-extremely-long-repository-name",
                fullName: "testuser/another-extremely-long-repository-name",
                description: nil,
                isPrivate: true,
                owner: createMockUser(),
                htmlURL: "https://github.com/testuser/another-long-name"
            )
        ]
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    func testSidebarViewNoDescriptions() {
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "project-alpha",
                fullName: "testuser/project-alpha",
                description: nil,
                isPrivate: false,
                owner: createMockUser(),
                htmlURL: "https://github.com/testuser/project-alpha"
            ),
            GitHubRepository(
                id: 2,
                name: "project-beta",
                fullName: "testuser/project-beta",
                description: nil,
                isPrivate: false,
                owner: createMockUser(),
                htmlURL: "https://github.com/testuser/project-beta"
            ),
            GitHubRepository(
                id: 3,
                name: "project-gamma",
                fullName: "testuser/project-gamma",
                description: nil,
                isPrivate: true,
                owner: createMockUser(),
                htmlURL: "https://github.com/testuser/project-gamma"
            )
        ]
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    // MARK: - Window Size Tests
    
    func testSidebarViewMinimumWidth() {
        appState.repositories = createMockRepositories()
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 320, height: 700) // Minimum width
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 320, height: 700)
    }
    
    func testSidebarViewMaximumWidth() {
        appState.repositories = createMockRepositories()
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 480, height: 700) // Maximum width
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 480, height: 700)
    }
    
    func testSidebarViewShortHeight() {
        appState.repositories = createMockRepositories()
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 400)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 400)
    }
    
    // MARK: - Dark Mode Tests
    
    func testSidebarViewDarkMode() {
        appState.repositories = createMockRepositories()
        appState.selectedView = .dashboard
        
        let view = SidebarView()
            .environmentObject(authService)
            .environmentObject(appState)
            .environment(\.gitHubAPIService, mockAPIService)
            .frame(width: 380, height: 700)
            .preferredColorScheme(.dark)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 380, height: 700)
    }
    
    // MARK: - Helper Methods
    
    private func createMockRepositories() -> [GitHubRepository] {
        let owner = createMockUser()
        
        return [
            GitHubRepository(
                id: 1,
                name: "ghast",
                fullName: "testuser/ghast",
                description: "GitHub Actions Self-hosted Tool",
                isPrivate: false,
                owner: owner,
                htmlURL: "https://github.com/testuser/ghast"
            ),
            GitHubRepository(
                id: 2,
                name: "awesome-project",
                fullName: "testuser/awesome-project",
                description: "An awesome project with CI/CD",
                isPrivate: false,
                owner: owner,
                htmlURL: "https://github.com/testuser/awesome-project"
            ),
            GitHubRepository(
                id: 3,
                name: "private-api",
                fullName: "testuser/private-api",
                description: "Private API implementation",
                isPrivate: true,
                owner: owner,
                htmlURL: "https://github.com/testuser/private-api"
            ),
            GitHubRepository(
                id: 4,
                name: "documentation",
                fullName: "testuser/documentation",
                description: "Project documentation and guides",
                isPrivate: false,
                owner: owner,
                htmlURL: "https://github.com/testuser/documentation"
            ),
            GitHubRepository(
                id: 5,
                name: "internal-tools",
                fullName: "testuser/internal-tools",
                description: nil,
                isPrivate: true,
                owner: owner,
                htmlURL: "https://github.com/testuser/internal-tools"
            )
        ]
    }
    
    private func createMockUser() -> GitHubUser {
        return GitHubUser(
            id: 12345,
            login: "testuser",
            avatarURL: "https://avatars.githubusercontent.com/u/12345",
            name: "Test User",
            email: "test@example.com"
        )
    }
}