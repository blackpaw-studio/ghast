import SwiftUI

/// Shown while the stored token lacks `admin:org`: repository features keep working,
/// organization runners need a fresh sign-in.
struct ScopeUpgradeBanner: View {
    let onSignIn: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "building.2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in again to manage organization runners")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Ghast now asks for organization access. Your repositories keep working in the meantime.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button("Sign In", action: onSignIn)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            // Opaque base so the tint reads the same over any detail view.
            ZStack {
                Color(NSColor.controlBackgroundColor)
                Color.purple.opacity(0.08)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Sheet for the in-app Device Flow started from `ScopeUpgradeBanner`.
struct ReSignInSheet: View {
    let signInState: SignInState
    let onOpenGitHub: (DeviceCode) -> Void
    let onTryAgain: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Sign in again")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("Approve organization access so Ghast can manage org runners.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            switch signInState {
            case .awaitingUser(let code):
                DeviceCodePanel(
                    code: code,
                    onOpenGitHub: { onOpenGitHub(code) },
                    onCopy: { DeviceFlowPresenter.copyToPasteboard(code.userCode) },
                    onCancel: onCancel
                )
            case .failed(let error):
                SignInFailurePanel(error: error, onTryAgain: onTryAgain)
                Button("Cancel", role: .cancel, action: onCancel)
            case .idle, .signedIn:
                ProgressView("Requesting a code from GitHub…")
                    .controlSize(.small)
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding(32)
        .frame(width: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

#Preview {
    ScopeUpgradeBanner(onSignIn: {}, onDismiss: {})
        .frame(width: 900)
}
