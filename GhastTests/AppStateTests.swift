import XCTest
@testable import Ghast

@MainActor
final class AppStateTests: XCTestCase {
    var appState: AppState!
    
    override func setUp() async throws {
        try await super.setUp()
        appState = AppState()
    }
    
    override func tearDown() async throws {
        appState = nil
        try await super.tearDown()
    }
    
    func testInitialState() {
        XCTAssertEqual(appState.selectedView, .dashboard)
        XCTAssertNil(appState.selectedRepository)
    }
    
    func testSelectViewChangesState() {
        let repo = GitHubRepository(
            id: 999,
            name: "test-repo",
            fullName: "user/test-repo",
            description: "Test",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "https://example.com/avatar.png", name: "Test User", email: nil),
            htmlURL: "https://github.com/user/test-repo"
        )
        
        appState.selectedView = .repository(repo)
        XCTAssertEqual(appState.selectedView, .repository(repo))
        
        appState.selectedView = .localRunners
        XCTAssertEqual(appState.selectedView, .localRunners)
        
        appState.selectedView = .settings
        XCTAssertEqual(appState.selectedView, .settings)
    }
    
    func testSelectRepositorySetsGitHubRepository() {
        let repo = GitHubRepository(
            id: 123,
            name: "test-repo",
            fullName: "user/test-repo",
            description: "Test repository",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "https://example.com/avatar.png", name: "Test User", email: nil),
            htmlURL: "https://github.com/user/test-repo"
        )
        
        appState.selectedRepository = repo
        XCTAssertEqual(appState.selectedRepository, repo)
        XCTAssertEqual(appState.selectedRepository?.id, 123)
        XCTAssertEqual(appState.selectedRepository?.name, "test-repo")
    }
    
    func testClearSelectedGitHubRepository() {
        let repo = GitHubRepository(
            id: 456,
            name: "another-repo",
            fullName: "user/another-repo",
            description: nil,
            isPrivate: true,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "https://example.com/avatar.png", name: "Test User", email: nil),
            htmlURL: "https://github.com/user/another-repo"
        )
        
        appState.selectedRepository = repo
        XCTAssertNotNil(appState.selectedRepository)
        
        appState.selectedRepository = nil
        XCTAssertNil(appState.selectedRepository)
    }
    
    func testNavigationFlow() {
        // Simulate typical navigation flow
        XCTAssertEqual(appState.selectedView, .dashboard)
        
        // Select a repository
        let repo = GitHubRepository(
            id: 789,
            name: "nav-test-repo",
            fullName: "user/nav-test-repo",
            description: "Navigation test",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "https://example.com/avatar.png", name: "Test User", email: nil),
            htmlURL: "https://github.com/user/nav-test-repo"
        )
        appState.selectedRepository = repo
        
        // Navigate to local runners with a selected repository
        appState.selectedView = .localRunners
        XCTAssertEqual(appState.selectedView, .localRunners)
        XCTAssertNotNil(appState.selectedRepository)
        
        // Navigate to settings
        appState.selectedView = .settings
        XCTAssertEqual(appState.selectedView, .settings)
        // Repository should still be selected
        XCTAssertNotNil(appState.selectedRepository)
    }
    
    func testStateObservability() async throws {
        // Test that state changes are observable
        let expectation = XCTestExpectation(description: "State change observed")
        
        let cancellable = appState.objectWillChange.sink { _ in
            expectation.fulfill()
        }
        
        appState.selectedView = .localRunners
        
        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()
    }
    
    func testConcurrentStateChanges() async throws {
        // Test that concurrent state changes don't cause issues
        let repo1 = GitHubRepository(
            id: 1001,
            name: "repo1",
            fullName: "user/repo1",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "https://example.com/avatar.png", name: "Test User", email: nil),
            htmlURL: "https://github.com/user/repo1"
        )
        
        let repo2 = GitHubRepository(
            id: 1002,
            name: "repo2",
            fullName: "user/repo2",
            description: nil,
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "user", avatarURL: "https://example.com/avatar.png", name: "Test User", email: nil),
            htmlURL: "https://github.com/user/repo2"
        )
        
        // Simulate rapid state changes
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                self.appState.selectedView = .dashboard
            }
            group.addTask { @MainActor in
                self.appState.selectedRepository = repo1
            }
            group.addTask { @MainActor in
                self.appState.selectedView = .localRunners
            }
            group.addTask { @MainActor in
                self.appState.selectedRepository = repo2
            }
        }
        
        // Verify final state is coherent
        XCTAssertNotNil(appState.selectedView)
        XCTAssertTrue([repo1, repo2, nil].contains(appState.selectedRepository))
    }
}