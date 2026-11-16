import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class AddRunnerViewSnapshotTests: XCTestCase {
    
    private func createTestRepository() -> GitHubRepository {
        GitHubRepository(
            id: 1,
            name: "test-repo",
            fullName: "testuser/test-repo",
            description: "A test repository for runner creation",
            isPrivate: false,
            owner: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil),
            htmlURL: "https://github.com/testuser/test-repo"
        )
    }
    
    func testAddRunnerViewDefault() async {
        let repository = createTestRepository()
        
        let view = AddRunnerView(scope: repository.runnerScope, repository: repository) {
            // Completion handler
        }
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1000, height: 750, record: false)
    }
    
    func testAddRunnerViewOrganizationScope() async {
        let view = AddRunnerView(scope: .organization(login: "acme")) {
            // Completion handler
        }
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1000, height: 750, record: false)
    }
    
    // MARK: - Platform Card Tests
    
    func testPlatformCardMacOSSelected() async {
        let application = GitHubRunnerApplication(
            os: "osx",
            architecture: "arm64",
            downloadURL: "https://example.com/runner-arm64.tar.gz",
            filename: "runner-arm64.tar.gz"
        )
        
        let view = PlatformCard(
            application: application,
            isSelected: true
        ) {
            // Action handler
        }
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 150, record: false)
    }
    
    func testPlatformCardMacOSUnselected() async {
        let application = GitHubRunnerApplication(
            os: "osx",
            architecture: "x64",
            downloadURL: "https://example.com/runner-x64.tar.gz",
            filename: "runner-x64.tar.gz"
        )
        
        let view = PlatformCard(
            application: application,
            isSelected: false
        ) {
            // Action handler
        }
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 200, height: 150, record: false)
    }
    
    func testPlatformSelectionGrid() async {
        let applications = [
            GitHubRunnerApplication(
                os: "osx",
                architecture: "arm64",
                downloadURL: "https://example.com/runner-arm64.tar.gz",
                filename: "runner-arm64.tar.gz"
            ),
            GitHubRunnerApplication(
                os: "osx",
                architecture: "x64",
                downloadURL: "https://example.com/runner-x64.tar.gz",
                filename: "runner-x64.tar.gz"
            )
        ]
        
        let grid = LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            ForEach(applications, id: \.downloadURL) { application in
                PlatformCard(
                    application: application,
                    isSelected: application.architecture == "arm64"
                ) {
                    // Action handler
                }
            }
        }
        
        SnapshotTestHelpers.assertSnapshot(of: grid, width: 450, height: 200, record: false)
    }
}