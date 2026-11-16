import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class ScopeUpgradeBannerSnapshotTests: XCTestCase {
    private let deviceCode = DeviceCode(
        deviceCode: "dev123",
        userCode: "WDJB-MJHT",
        verificationURI: URL(string: "https://github.com/login/device")!,
        expiresIn: 900,
        interval: 5
    )

    func testBanner() {
        let view = ScopeUpgradeBanner(onSignIn: {}, onDismiss: {})

        SnapshotTestHelpers.assertSnapshot(of: view, width: 900, height: 64)
    }

    func testMainAppViewShowsBannerWhenScopeUpgradeNeeded() {
        let authService = MockGitHubAuthService()
        authService.setAuthenticatedState(user: GitHubUser(id: 1, login: "testuser", avatarURL: "", name: "Test User", email: nil))
        authService.stubbedNeedsScopeUpgrade = true
        let appState = AppState()
        appState.selectedView = .localRunners

        let view = MainAppView()
            .environment(authService as GitHubAuthService)
            .environment(appState)

        SnapshotTestHelpers.assertSnapshot(of: view, width: 1200, height: 800)
    }

    func testReSignInSheetAwaitingUser() {
        let view = ReSignInSheet(signInState: .awaitingUser(deviceCode), onOpenGitHub: { _ in }, onTryAgain: {}, onCancel: {})

        SnapshotTestHelpers.assertSnapshot(of: view, width: 560, height: 380)
    }

    func testReSignInSheetFailed() {
        let view = ReSignInSheet(signInState: .failed(.denied), onOpenGitHub: { _ in }, onTryAgain: {}, onCancel: {})

        SnapshotTestHelpers.assertSnapshot(of: view, width: 560, height: 320)
    }
}
