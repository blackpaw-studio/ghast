import SwiftUI

/// Grant…: Device Flow again, for a token with every scope, in the device-code view.
struct GrantAccessSheet: View {
    let authService: GitHubAuthService
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch authService.signInState {
            case let .awaitingUser(code):
                DeviceCodeView(
                    code: code,
                    copyCode: { DeviceFlowPresenter.copyToPasteboard(code.userCode) },
                    openGitHub: { openURL(code.verificationURI) },
                    cancel: close
                )
            case let .failed(error):
                failed(error)
            case .idle, .signedIn:
                ProgressView()
                    .frame(width: FocusMetrics.welcomeWindow.width, height: FocusMetrics.welcomeWindow.height)
            }
        }
        .presentsDeviceFlow(authService.signInState)
    }

    private func failed(_ error: DeviceFlowError) -> some View {
        VStack(spacing: FocusMetrics.settingsSignOutHelpGap) {
            Text("Couldn’t Grant Access").font(FocusType.title2)
            Text(error.userMessage)
                .font(FocusType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Try Again") { Task { await authService.signIn() } }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(FocusMetrics.sheetPadding)
        .frame(width: FocusMetrics.sheetWidth)
    }
}
