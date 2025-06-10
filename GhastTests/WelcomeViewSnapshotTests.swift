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
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600)
    }
    
    func testWelcomeViewDarkMode() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)
            .preferredColorScheme(.dark)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 800, height: 600)
    }
    
    func testWelcomeViewSmallWindow() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 600, height: 450)
    }
    
    func testWelcomeViewLargeWindow() async {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        
        let view = WelcomeView()
            .environmentObject(authService as GitHubAuthService)
        
        SnapshotTestHelpers.assertSnapshot(of: view, width: 1000, height: 750)
    }
}