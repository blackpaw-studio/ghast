import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class WelcomeViewSnapshotTests: XCTestCase {
    
    func testWelcomeViewDefault() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600, record: false)
    }
    
    func testWelcomeViewDarkMode() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)
            .preferredColorScheme(.dark)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600, record: false)
    }
    
    func testWelcomeViewSmallWindow() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 600, height: 450, record: false)
    }
    
    func testWelcomeViewLargeWindow() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1000, height: 750, record: false)
    }

    func testWelcomeViewAwaitingUser() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        authService.setSignInState(.awaitingUser(DeviceCode(
            deviceCode: "dev123",
            userCode: "WDJB-MJHT",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        )))

        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)

        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 700, record: false)
    }

    func testWelcomeViewFailed() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        authService.setSignInState(.failed(.expired))

        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)

        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 700, record: false)
    }
}
