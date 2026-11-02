import XCTest
import SwiftUI
import SnapshotTesting
@testable import Ghast

/// Every sign-in state must fit fully, unclipped, at the sizes the app really opens at.
/// Sizes come from ContentView (min 1200×650 content) and GhastApp (defaultSize 1000×700,
/// widened to the 1200 minimum); `observed` is the smaller real-world window from the bug report.
@MainActor
final class WelcomeViewSnapshotTests: XCTestCase {
    private enum WindowSize {
        static let appDefault = CGSize(width: 1200, height: 700)
        static let appMinimum = CGSize(width: 1200, height: 650)
        static let observed = CGSize(width: 1000, height: 530)
    }

    private let deviceCode = DeviceCode(
        deviceCode: "dev123",
        userCode: "WDJB-MJHT",
        verificationURI: URL(string: "https://github.com/login/device")!,
        expiresIn: 900,
        interval: 5
    )

    private func makeView(_ state: SignInState?, dark: Bool = false) -> some View {
        let authService = MockGitHubAuthService()
        authService.setUnauthenticatedState()
        if let state { authService.setSignInState(state) }
        return WelcomeView()
            .environmentObject(authService as GitHubAuthService)
            .preferredColorScheme(dark ? .dark : nil)
    }

    private func assert(_ state: SignInState?, _ size: CGSize, dark: Bool = false, testName: String = #function) {
        SnapshotTestHelpers.assertSnapshot(of: makeView(state, dark: dark), width: size.width, height: size.height, record: false, testName: testName)
    }

    func testIdleAtDefaultSize() { assert(nil, WindowSize.appDefault) }
    func testIdleAtMinimumSize() { assert(nil, WindowSize.appMinimum) }
    func testIdleAtObservedSize() { assert(nil, WindowSize.observed) }
    func testIdleDarkMode() { assert(nil, WindowSize.appDefault, dark: true) }

    func testAwaitingUserAtDefaultSize() { assert(.awaitingUser(deviceCode), WindowSize.appDefault) }
    func testAwaitingUserAtMinimumSize() { assert(.awaitingUser(deviceCode), WindowSize.appMinimum) }
    func testAwaitingUserAtObservedSize() { assert(.awaitingUser(deviceCode), WindowSize.observed) }

    func testFailedAtDefaultSize() { assert(.failed(.expired), WindowSize.appDefault) }
    func testFailedAtMinimumSize() { assert(.failed(.expired), WindowSize.appMinimum) }
    func testFailedAtObservedSize() { assert(.failed(.expired), WindowSize.observed) }
}
