import SwiftUI
import AppKit

/// The Welcome window's content: Welcome, or the device code while an attempt waits.
struct WelcomeWindowRoot: View {
    let authService: GitHubAuthService
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch authService.signInState {
            case let .awaitingUser(code):
                DeviceCodeView(
                    code: code,
                    copyCode: { DeviceFlowPresenter.copyToPasteboard(code.userCode) },
                    openGitHub: { openURL(code.verificationURI) },
                    cancel: { authService.cancelSignIn() }
                )
            case let .failed(error):
                WelcomeView(failure: error, signIn: signIn)
            case .idle, .signedIn:
                WelcomeView(failure: nil, signIn: signIn)
            }
        }
        // AppKit adds the (hidden) title bar above the content size SwiftUI asks for, so the
        // content asks for 520 minus the title bar and the 520 pt view reaches up under it:
        // the window is exactly the kit's 560 × 520.
        .frame(
            width: FocusMetrics.welcomeWindow.width,
            height: FocusMetrics.welcomeWindow.height - Self.titleBarHeight,
            alignment: .bottom
        )
        .presentsDeviceFlow(authService.signInState)
        .switchesWindowsOnAuthChange(authService, in: .welcome)
    }

    /// The title bar AppKit puts above a window's content rect.
    static let titleBarHeight: CGFloat = {
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled, .closable, .miniaturizable]).height - content.height
    }()

    private func signIn() {
        Task { await authService.signIn() }
    }
}

/// Which of the two top-level windows a view lives in.
enum AuthWindow {
    case main, welcome

    static let mainID = "main"
    static let welcomeID = "welcome"
}

/// Signing in swaps the Welcome window for the main one; signing out (or a stored token that
/// no longer works) swaps back.
private struct AuthWindowSwitch: ViewModifier {
    let authService: GitHubAuthService
    let window: AuthWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var isSignedOut: Bool { !authService.isCheckingStoredAuth && !authService.isAuthenticated }

    func body(content: Content) -> some View {
        content.onChange(of: isSignedOut, initial: true) { _, signedOut in
            switch window {
            case .main where signedOut:
                openWindow(id: AuthWindow.welcomeID)
                dismissWindow(id: AuthWindow.mainID)
            case .welcome where authService.isAuthenticated:
                openWindow(id: AuthWindow.mainID)
                dismissWindow(id: AuthWindow.welcomeID)
            default:
                break
            }
        }
    }
}

extension View {
    func switchesWindowsOnAuthChange(_ authService: GitHubAuthService, in window: AuthWindow) -> some View {
        modifier(AuthWindowSwitch(authService: authService, window: window))
    }
}
