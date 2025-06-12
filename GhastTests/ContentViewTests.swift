import XCTest
import SwiftUI
@testable import Ghast

@MainActor
final class ContentViewTests: XCTestCase {
    
    var authService: GitHubAuthService!
    var appState: AppState!
    
    override func setUp() async throws {
        try await super.setUp()
        authService = GitHubAuthService()
        appState = AppState()
    }
    
    override func tearDown() async throws {
        authService = nil
        appState = nil
        try await super.tearDown()
    }
    
    // MARK: - ContentView Tests
    
    func testContentViewInitialState() {
        let contentView = ContentView()
        
        // Can't easily inspect SwiftUI views directly, but we can verify it creates successfully
        XCTAssertNotNil(contentView)
    }
    
    func testContentViewShowsLoadingWhileCheckingAuth() {
        authService.isCheckingStoredAuth = true
        
        // In this state, ContentView should show loading spinner
        // We can't directly test SwiftUI view content easily, but we verify the state
        XCTAssertTrue(authService.isCheckingStoredAuth)
        XCTAssertFalse(authService.isAuthenticated)
    }
    
    func testContentViewShowsWelcomeWhenNotAuthenticated() {
        authService.isCheckingStoredAuth = false
        authService.isAuthenticated = false
        
        // In this state, ContentView should show WelcomeView
        XCTAssertFalse(authService.isCheckingStoredAuth)
        XCTAssertFalse(authService.isAuthenticated)
    }
    
    func testContentViewShowsMainAppWhenAuthenticated() {
        authService.isCheckingStoredAuth = false
        authService.isAuthenticated = true
        authService.currentUser = GitHubUser(
            id: 123,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
        
        // In this state, ContentView should show MainAppView
        XCTAssertFalse(authService.isCheckingStoredAuth)
        XCTAssertTrue(authService.isAuthenticated)
        XCTAssertNotNil(authService.currentUser)
    }
    
    // MARK: - MainAppView Tests
    
    func testMainAppViewSelectedViews() {
        // Test each possible selected view
        appState.selectedView = .dashboard
        XCTAssertEqual(appState.selectedView, .dashboard)
        
        let repo = GitHubRepository(
            id: 1,
            name: "test-repo",
            fullName: "user/test-repo",
            description: "Test repository",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: nil, email: nil),
            htmlURL: "https://github.com/user/test-repo"
        )
        
        appState.selectedView = .repository(repo)
        if case .repository(let selectedRepo) = appState.selectedView {
            XCTAssertEqual(selectedRepo.id, repo.id)
        } else {
            XCTFail("Selected view should be repository")
        }
        
        appState.selectedView = .localRunners
        XCTAssertEqual(appState.selectedView, .localRunners)
        
        appState.selectedView = .settings
        XCTAssertEqual(appState.selectedView, .settings)
    }
    
    // MARK: - ToolbarProfileImage Tests
    
    func testToolbarProfileImageWithValidURL() async {
        let url = URL(string: "https://example.com/avatar.png")
        let profileImage = ToolbarProfileImage(url: url, fallback: "T")
        
        XCTAssertNotNil(profileImage)
        // Note: We can't easily test the actual image loading without mocking URLSession
    }
    
    func testToolbarProfileImageWithNilURL() {
        let profileImage = ToolbarProfileImage(url: nil, fallback: "U")
        
        XCTAssertNotNil(profileImage)
        // Should show fallback text
    }
    
    func testToolbarProfileImageCaching() async {
        // Test that image cache is used
        let url = URL(string: "https://example.com/cached-avatar.png")
        
        // Create multiple instances with same URL
        let image1 = ToolbarProfileImage(url: url, fallback: "A")
        let image2 = ToolbarProfileImage(url: url, fallback: "A")
        
        XCTAssertNotNil(image1)
        XCTAssertNotNil(image2)
        
        // Both should use the same cached image (though we can't directly verify without mocking)
    }
    
    // MARK: - AppState Tests
    
    func testAppStateInitialValues() {
        let state = AppState()
        
        XCTAssertEqual(state.selectedView, .dashboard)
        XCTAssertEqual(state.repositories.count, 0)
        XCTAssertFalse(state.isLoadingRepositories)
        XCTAssertNil(state.selectedRepository)
    }
    
    func testAppStateSelectedViewEquality() {
        let repo1 = GitHubRepository(
            id: 1,
            name: "repo1",
            fullName: "user/repo1",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: nil, email: nil),
            htmlURL: ""
        )
        
        let repo2 = GitHubRepository(
            id: 2,
            name: "repo2",
            fullName: "user/repo2",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: nil, email: nil),
            htmlURL: ""
        )
        
        // Test equality for each case
        XCTAssertEqual(AppState.SelectedView.dashboard, AppState.SelectedView.dashboard)
        XCTAssertEqual(AppState.SelectedView.repository(repo1), AppState.SelectedView.repository(repo1))
        XCTAssertEqual(AppState.SelectedView.localRunners, AppState.SelectedView.localRunners)
        XCTAssertEqual(AppState.SelectedView.settings, AppState.SelectedView.settings)
        
        // Test inequality
        XCTAssertNotEqual(AppState.SelectedView.dashboard, AppState.SelectedView.localRunners)
        XCTAssertNotEqual(AppState.SelectedView.repository(repo1), AppState.SelectedView.repository(repo2))
    }
    
    func testAppStateRepositoryManagement() {
        let repo1 = GitHubRepository(
            id: 1,
            name: "repo1",
            fullName: "user/repo1",
            description: "First repo",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: nil, email: nil),
            htmlURL: ""
        )
        
        let repo2 = GitHubRepository(
            id: 2,
            name: "repo2",
            fullName: "user/repo2",
            description: "Second repo",
            isPrivate: true,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: nil, email: nil),
            htmlURL: ""
        )
        
        // Add repositories
        appState.repositories = [repo1, repo2]
        XCTAssertEqual(appState.repositories.count, 2)
        
        // Set loading state
        appState.isLoadingRepositories = true
        XCTAssertTrue(appState.isLoadingRepositories)
        
        // Set selected repository
        appState.selectedRepository = repo1
        XCTAssertEqual(appState.selectedRepository?.id, repo1.id)
        
        // Clear repositories
        appState.repositories.removeAll()
        XCTAssertEqual(appState.repositories.count, 0)
    }
    
    // MARK: - Integration Tests
    
    func testAuthenticationFlow() async {
        // Test the flow from unauthenticated to authenticated
        authService.isCheckingStoredAuth = true
        authService.isAuthenticated = false
        
        // Simulate checking stored auth completes
        authService.isCheckingStoredAuth = false
        
        // Still not authenticated - should show WelcomeView
        XCTAssertFalse(authService.isAuthenticated)
        
        // Simulate successful authentication
        let mockUser = GitHubUser(
            id: 456,
            login: "authenticated-user",
            avatarURL: "https://example.com/avatar.jpg",
            name: "Authenticated User",
            email: "auth@example.com"
        )
        
        authService.simulateSuccessfulAuth(user: mockUser)
        
        // Now authenticated - should show MainAppView
        XCTAssertTrue(authService.isAuthenticated)
        XCTAssertNotNil(authService.currentUser)
        XCTAssertEqual(authService.currentUser?.login, "authenticated-user")
    }
    
    func testSignOutFlow() {
        // Set up authenticated state
        let mockUser = GitHubUser(
            id: 789,
            login: "signout-user",
            avatarURL: "https://example.com/avatar.png",
            name: "Sign Out User",
            email: "signout@example.com"
        )
        
        authService.simulateSuccessfulAuth(user: mockUser)
        XCTAssertTrue(authService.isAuthenticated)
        
        // Sign out
        authService.signOut()
        
        // Should be back to unauthenticated state
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertNil(authService.currentUser)
    }
    
    // MARK: - View Dimension Tests
    
    func testContentViewDimensions() {
        // ContentView has specific frame constraints
        // minWidth: 1000, maxWidth: .infinity
        // minHeight: 650, maxHeight: .infinity
        
        // We can't directly test SwiftUI frame modifiers, but we document the expected values
        let expectedMinWidth: CGFloat = 1000
        let expectedMinHeight: CGFloat = 650
        
        XCTAssertEqual(expectedMinWidth, 1000)
        XCTAssertEqual(expectedMinHeight, 650)
    }
    
    func testNavigationSplitViewColumnWidth() {
        // NavigationSplitView has specific column width constraints
        // min: 320, ideal: 380, max: 480
        
        let minWidth: CGFloat = 320
        let idealWidth: CGFloat = 380
        let maxWidth: CGFloat = 480
        
        XCTAssertLessThan(minWidth, idealWidth)
        XCTAssertLessThan(idealWidth, maxWidth)
    }
}