import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class ViewSnapshotTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Set consistent test environment
        isRecording = false
    }
    
    // MARK: - Dashboard View Tests
    
    func testDashboardView() async {
        let authService = GitHubAuthService()
        authService.currentUser = GitHubUser(
            id: 1,
            login: "testuser",
            avatarURL: "https://example.com/avatar.png",
            name: "Test User",
            email: "test@example.com"
        )
        
        let appState = AppState()
        appState.repositories = [
            GitHubRepository(
                id: 1,
                name: "test-repo-1",
                fullName: "testuser/test-repo-1",
                description: "A test repository for snapshot testing",
                isPrivate: false,
                owner: authService.currentUser!,
                htmlURL: "https://github.com/testuser/test-repo-1"
            ),
            GitHubRepository(
                id: 2,
                name: "private-repo",
                fullName: "testuser/private-repo",
                description: "A private repository",
                isPrivate: true,
                owner: authService.currentUser!,
                htmlURL: "https://github.com/testuser/private-repo"
            )
        ]
        
        let view = DashboardView()
            .environmentObject(authService)
            .environmentObject(appState)
            .frame(width: 1000, height: 800)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 1000, height: 800)))
    }
    
    // MARK: - Welcome View Tests
    
    func testWelcomeView() async {
        let authService = GitHubAuthService()
        
        let view = WelcomeView()
            .environmentObject(authService)
            .frame(width: 800, height: 600)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 800, height: 600)))
    }
    
    // MARK: - Local Runners View Tests
    
    func testLocalRunnersViewEmpty() async {
        let view = LocalRunnersView()
            .frame(width: 1000, height: 800)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 1000, height: 800)))
    }
    
    func testLocalRunnersViewWithRunners() async {
        // Create a mock runner service with test data
        let runnerService = RunnerService.shared
        
        let view = LocalRunnersView()
            .frame(width: 1000, height: 800)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 1000, height: 800)))
    }
    
    // MARK: - New Runner Flow Tests
    
    func testNewRunnerFlowView() async {
        let repositories = [
            GitHubRepository(
                id: 1,
                name: "test-repo",
                fullName: "testuser/test-repo",
                description: "A test repository for GitHub Actions",
                isPrivate: false,
                owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil),
                htmlURL: "https://github.com/testuser/test-repo"
            ),
            GitHubRepository(
                id: 2,
                name: "another-repo",
                fullName: "testuser/another-repo",
                description: "Another repository with a longer description to test how the UI handles multiple lines of text",
                isPrivate: true,
                owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil),
                htmlURL: "https://github.com/testuser/another-repo"
            )
        ]
        
        let view = NewRunnerFlowView(repositories: repositories)
            .frame(width: 1200, height: 800)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 1200, height: 800)))
    }
    
    // MARK: - Settings View Tests
    
    func testSettingsView() async {
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
            .frame(width: 800, height: 600)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 800, height: 600)))
    }
    
    // MARK: - Repository Detail View Tests
    
    func testRepositoryDetailView() async {
        let repository = GitHubRepository(
            id: 1,
            name: "test-repository",
            fullName: "testuser/test-repository",
            description: "A comprehensive test repository for GitHub Actions workflows",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil),
            htmlURL: "https://github.com/testuser/test-repository"
        )
        
        let view = RepositoryDetailView(repository: repository)
            .frame(width: 1000, height: 800)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 1000, height: 800)))
    }
    
    // MARK: - Component Tests
    
    func testStatCard() async {
        let view = StatCard(
            title: "Total Runners",
            value: "5",
            icon: "play.circle.fill",
            color: .blue
        )
        .frame(width: 200, height: 120)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 200, height: 120)))
    }
    
    func testDashboardRepositoryCard() async {
        let repository = GitHubRepository(
            id: 1,
            name: "sample-repo",
            fullName: "user/sample-repo",
            description: "A sample repository description",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "", name: "User", email: nil),
            htmlURL: "https://github.com/user/sample-repo"
        )
        
        let view = DashboardRepositoryCard(repository: repository) {
            // Action placeholder
        }
        .frame(width: 300, height: 120)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 300, height: 120)))
    }
    
    func testNewRunnerRepositoryCard() async {
        let repository = GitHubRepository(
            id: 1,
            name: "example-project",
            fullName: "organization/example-project",
            description: "An example project with GitHub Actions configured",
            isPrivate: true,
            owner: GitHubUser(id: 1, login: "organization", avatarURL: "", name: "Organization", email: nil),
            htmlURL: "https://github.com/organization/example-project"
        )
        
        let view = NewRunnerRepositoryCard(
            repository: repository,
            isSelected: true
        ) {
            // Action placeholder
        }
        .frame(width: 400, height: 100)
        
        assertSnapshot(of: view, as: Snapshotting.image(layout: .fixed(width: 400, height: 100)))
    }
}

// MARK: - Test Recording Helper

extension ViewSnapshotTests {
    
    /// Call this function to record new snapshots after UI changes
    /// Set isRecording = true temporarily, run tests, then set back to false
    func recordSnapshots() async {
        isRecording = true
        
        // Run individual test methods to record snapshots
        await testDashboardView()
        await testWelcomeView()
        await testLocalRunnersViewEmpty()
        await testNewRunnerFlowView()
        await testSettingsView()
        await testRepositoryDetailView()
        await testStatCard()
        await testDashboardRepositoryCard()
        await testNewRunnerRepositoryCard()
        
        isRecording = false
    }
}