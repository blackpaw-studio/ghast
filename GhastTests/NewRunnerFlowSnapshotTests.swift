import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class NewRunnerFlowSnapshotTests: XCTestCase {
    
    private func createMockRepositories() -> [GitHubRepository] {
        let user = GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil)
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
                description: "A private repository with sensitive data and complex workflows",
                isPrivate: true,
                owner: user,
                htmlURL: "https://github.com/testuser/private-project"
            ),
            GitHubRepository(
                id: 3,
                name: "no-description",
                fullName: "testuser/no-description",
                description: nil,
                isPrivate: false,
                owner: user,
                htmlURL: "https://github.com/testuser/no-description"
            )
        ]
    }
    
    func testNewRunnerFlowWithRepositories() async {
        let repositories = createMockRepositories()
        
        let view = NewRunnerFlowView(repositories: repositories)
            .frame(width: 1200, height: 800)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testNewRunnerFlowEmpty() async {
        let view = NewRunnerFlowView(repositories: [])
            .frame(width: 1200, height: 800)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testNewRunnerFlowSmallWindow() async {
        let repositories = Array(createMockRepositories().prefix(2))
        
        let view = NewRunnerFlowView(repositories: repositories)
            .frame(width: 1000, height: 700)
        
        assertSnapshot(of: view, as: .image)
    }
}