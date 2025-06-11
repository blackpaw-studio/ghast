import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class RepositoryDetailViewSnapshotTests: XCTestCase {
    
    private func createTestRepository() -> GitHubRepository {
        GitHubRepository(
            id: 1,
            name: "ghast",
            fullName: "testuser/ghast",
            description: "A macOS app for managing GitHub Actions self-hosted runners",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil),
            htmlURL: "https://github.com/testuser/ghast"
        )
    }
    
    private func createPrivateRepository() -> GitHubRepository {
        GitHubRepository(
            id: 2,
            name: "private-project",
            fullName: "testuser/private-project",
            description: "A private repository with sensitive workflows and deployment automation",
            isPrivate: true,
            owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil),
            htmlURL: "https://github.com/testuser/private-project"
        )
    }
    
    func testRepositoryDetailViewEmpty() async {
        let repository = createTestRepository()
        
        let view = RepositoryDetailView(repository: repository)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1000, height: 700, record: false)
    }
    
    func testRepositoryDetailViewPrivate() async {
        let repository = createPrivateRepository()
        
        let view = RepositoryDetailView(repository: repository)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1000, height: 700, record: false)
    }
    
    func testRepositoryDetailViewLargeWindow() async {
        let repository = createTestRepository()
        
        let view = RepositoryDetailView(repository: repository)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1400, height: 900, record: false)
    }
    
    func testRepositoryDetailViewSmallWindow() async {
        let repository = createTestRepository()
        
        let view = RepositoryDetailView(repository: repository)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600, record: false)
    }
}