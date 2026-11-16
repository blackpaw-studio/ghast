import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class OrganizationDetailViewSnapshotTests: XCTestCase {
    private let organization = GitHubOrganization(login: "acme", id: 10, avatarURL: "")

    private func remoteRunner(id: Int, name: String, status: String, busy: Bool, labels: [String]) -> GitHubRunner {
        GitHubRunner(
            id: id,
            name: name,
            os: "macOS",
            status: status,
            busy: busy,
            labels: labels.enumerated().map { GitHubRunnerLabel(id: $0.offset, name: $0.element, type: "custom") }
        )
    }

    func testOrganizationDetailViewEmpty() async {
        let view = OrganizationDetailView(organization: organization)

        await SnapshotTestHelpers.assertSettledSnapshot(of: view, width: 1000, height: 700)
    }

    /// One remote runner matches a local org runner by name and must not be listed twice;
    /// a local runner for a repository must not appear on the org page.
    func testOrganizationDetailViewPopulated() async {
        let apiService = MockGitHubAPIService()
        apiService.mockRunners = [
            remoteRunner(id: 1, name: "acme-mac-mini", status: "online", busy: true, labels: ["self-hosted", "macOS", "ARM64"]),
            remoteRunner(id: 2, name: "acme-build-02", status: "offline", busy: false, labels: ["self-hosted"]),
            remoteRunner(id: 3, name: "this-mac", status: "online", busy: false, labels: ["self-hosted"]),
        ]
        let runnerService = makeTestRunnerService(runners: [
            LocalRunner(name: "this-mac", scope: .organization(login: "acme"), path: "/tmp/ghast-nonexistent-this-mac", labels: ["self-hosted"]),
            LocalRunner(name: "repo-only", repository: "acme/web", path: "/tmp/ghast-nonexistent-repo-only", labels: ["self-hosted"]),
        ])

        let view = OrganizationDetailView(organization: organization)
            .environment(\.gitHubAPIService, apiService)

        await SnapshotTestHelpers.assertSettledSnapshot(of: view, width: 1000, height: 900, runnerService: runnerService)
    }
}
