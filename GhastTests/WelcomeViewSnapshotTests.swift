import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

@MainActor
final class WelcomeViewSnapshotTests: XCTestCase {
    
    func testWelcomeViewDefault() async {
        let authService = GitHubAuthService()
        
        let view = WelcomeView()
            .environmentObject(authService)
            .frame(width: 800, height: 600)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testWelcomeViewDarkMode() async {
        let authService = GitHubAuthService()
        
        let view = WelcomeView()
            .environmentObject(authService)
            .frame(width: 800, height: 600)
            .preferredColorScheme(.dark)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testWelcomeViewSmallWindow() async {
        let authService = GitHubAuthService()
        
        let view = WelcomeView()
            .environmentObject(authService)
            .frame(width: 600, height: 450)
        
        assertSnapshot(of: view, as: .image)
    }
    
    func testWelcomeViewLargeWindow() async {
        let authService = GitHubAuthService()
        
        let view = WelcomeView()
            .environmentObject(authService)
            .frame(width: 1000, height: 750)
        
        assertSnapshot(of: view, as: .image)
    }
}