import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class RepositoryCardSnapshotTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        isRecording = false
    }
    
    private func createTestRepository(
        name: String,
        description: String?,
        isPrivate: Bool
    ) -> GitHubRepository {
        let user = GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil)
        return GitHubRepository(
            id: 1,
            name: name,
            fullName: "testuser/\(name)",
            description: description,
            isPrivate: isPrivate,
            owner: user,
            htmlURL: "https://github.com/testuser/\(name)"
        )
    }
    
    // MARK: - Dashboard Repository Card Tests
    
    func testDashboardRepositoryCardPublic() async {
        let repository = createTestRepository(
            name: "public-repo",
            description: "A public repository with a description",
            isPrivate: false
        )
        
        let view = DashboardRepositoryCard(repository: repository) {
            // Action handler
        }
        .frame(width: 300, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardRepositoryCardPrivate() async {
        let repository = createTestRepository(
            name: "private-repo",
            description: "A private repository with sensitive data",
            isPrivate: true
        )
        
        let view = DashboardRepositoryCard(repository: repository) {
            // Action handler
        }
        .frame(width: 300, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardRepositoryCardNoDescription() async {
        let repository = createTestRepository(
            name: "no-description",
            description: nil,
            isPrivate: false
        )
        
        let view = DashboardRepositoryCard(repository: repository) {
            // Action handler
        }
        .frame(width: 300, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardRepositoryCardLongName() async {
        let repository = createTestRepository(
            name: "very-long-repository-name-that-should-be-truncated",
            description: "This repository has a very long name to test truncation",
            isPrivate: false
        )
        
        let view = DashboardRepositoryCard(repository: repository) {
            // Action handler
        }
        .frame(width: 300, height: 120)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testDashboardRepositoryCardDarkMode() async {
        let repository = createTestRepository(
            name: "test-repo",
            description: "Testing dark mode",
            isPrivate: false
        )
        
        let view = DashboardRepositoryCard(repository: repository) {
            // Action handler
        }
        .frame(width: 300, height: 120)
        .preferredColorScheme(.dark)
        
        assertSnapshot(of: view, as: .image)
    }
    
    // MARK: - New Runner Repository Card Tests
    
    func testNewRunnerRepositoryCardSelected() async {
        let repository = createTestRepository(
            name: "selected-repo",
            description: "This repository is currently selected",
            isPrivate: false
        )
        
        let view = NewRunnerRepositoryCard(
            repository: repository,
            isSelected: true
        ) {
            // Action handler
        }
        .frame(width: 400, height: 100)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testNewRunnerRepositoryCardUnselected() async {
        let repository = createTestRepository(
            name: "unselected-repo",
            description: "This repository is not selected",
            isPrivate: true
        )
        
        let view = NewRunnerRepositoryCard(
            repository: repository,
            isSelected: false
        ) {
            // Action handler
        }
        .frame(width: 400, height: 100)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testNewRunnerRepositoryCardLongDescription() async {
        let repository = createTestRepository(
            name: "detailed-repo",
            description: "This repository has a very detailed description that explains what the project does and might need to be truncated if it's too long for the available space",
            isPrivate: true
        )
        
        let view = NewRunnerRepositoryCard(
            repository: repository,
            isSelected: true
        ) {
            // Action handler
        }
        .frame(width: 400, height: 100)
        
        assertSnapshot(of: view, as: .image)
    }
    
    // MARK: - Grid Layout Tests
    
    func testRepositoryCardsGrid() async {
        let repositories = [
            createTestRepository(name: "repo-1", description: "First repository", isPrivate: false),
            createTestRepository(name: "repo-2", description: "Second repository", isPrivate: true),
            createTestRepository(name: "repo-3", description: nil, isPrivate: false)
        ]
        
        let grid = LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            ForEach(repositories) { repository in
                DashboardRepositoryCard(repository: repository) {
                    // Action handler
                }
            }
        }
        .frame(width: 650, height: 250)
        
        assertSnapshot(of: grid, as: .image)
    }
}