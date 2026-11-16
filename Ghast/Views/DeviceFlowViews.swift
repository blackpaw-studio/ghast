import SwiftUI

extension DeviceFlowError {
    /// Plain-language explanation shown under the failure banner. `.disabled` is
    /// aimed at the developer who owns the OAuth app.
    var userMessage: String {
        switch self {
        case .expired:
            return "The code expired before it was approved. Try again to get a new one."
        case .denied:
            return "Access was denied on GitHub. Try again if that was a mistake."
        case .network(let detail):
            return "Couldn't reach GitHub. Check your connection and try again. (\(detail))"
        case .disabled:
            return "Device Flow is turned off for Ghast's OAuth app. Enable it under \"Enable Device Flow\" in the app's settings on GitHub."
        case .unexpected(let detail):
            return "GitHub sent an unexpected response (\(detail)). Try again."
        case .storage(let detail):
            return "Couldn't save your sign-in to the Keychain (\(detail)). Try again."
        }
    }
}

/// Shows the user code while the app polls for approval.
struct DeviceCodePanel: View {
    let code: DeviceCode
    let onOpenGitHub: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Enter this code on GitHub")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(code.userCode)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.blue.opacity(0.08))
                )

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval… the code is copied to your clipboard.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Open GitHub", action: onOpenGitHub)
                    .buttonStyle(.borderedProminent)
                Button("Copy code", action: onCopy)
                Button("Cancel", role: .cancel, action: onCancel)
            }
            .controlSize(.large)
        }
    }
}

/// Shown when sign-in failed, with a way to start over.
struct SignInFailurePanel: View {
    let error: DeviceFlowError
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.userMessage)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)

            Button("Try again", action: onTryAgain)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
