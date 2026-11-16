import SwiftUI

/// "Enter This Code on GitHub" (Welcome.png, right), with the waiting footer bar. Settings
/// reuses it for the organization access grant.
struct DeviceCodeView: View {
    let code: DeviceCode
    let copyCode: () -> Void
    let openGitHub: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // The kit draws the key on the diagonal, bow to the upper left.
                Image(systemName: "key")
                    .font(.system(size: FocusMetrics.deviceKeyGlyph * 0.75))
                    .rotationEffect(.degrees(FocusMetrics.deviceKeyRotation))
                    .foregroundStyle(.tint)
                    .frame(width: FocusMetrics.deviceKeyGlyph, height: FocusMetrics.deviceKeyGlyph)
                    .accessibilityHidden(true)
                    .padding(.top, FocusMetrics.deviceKeyTop)
                Text("Enter This Code on GitHub")
                    .font(FocusType.title1)
                    .padding(.top, FocusMetrics.deviceTitleGap)
                Text("Ghast opened \(Self.displayHost(code.verificationURI)) in your browser. Enter this code there to finish signing in.")
                    .font(FocusType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(FocusMetrics.deviceBodyLineSpacing)
                    .frame(maxWidth: FocusMetrics.deviceBodyMaxWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FocusMetrics.deviceBodyGap)
                DeviceCodeBox(code: code.userCode)
                    .padding(.top, FocusMetrics.deviceCodeGap)
                HStack(spacing: FocusMetrics.deviceButtonSpacing) {
                    Button(action: copyCode) { LargeButtonTitle("Copy Code") }
                    Button(action: openGitHub) { LargeButtonTitle("Open GitHub") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, FocusMetrics.deviceButtonsGap)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Divider()
            HStack(spacing: FocusMetrics.deviceFooterSpinnerGap) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to approve…")
                    .font(FocusType.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, FocusMetrics.deviceFooterLeadingInset)
            .padding(.trailing, FocusMetrics.deviceFooterInset)
            .frame(height: FocusMetrics.deviceFooterHeight)
        }
        .frame(width: FocusMetrics.welcomeWindow.width, height: FocusMetrics.welcomeWindow.height)
    }

    /// "github.com/login/device", without the scheme.
    static func displayHost(_ url: URL) -> String {
        let text = url.absoluteString
        guard let range = text.range(of: "://") else { return text }
        return String(text[range.upperBound...])
    }
}

/// The user code in large mono type on a quiet rounded box.
struct DeviceCodeBox: View {
    let code: String

    private static let tracking = FocusMetrics.deviceCodeFontSize * FocusMetrics.deviceCodeTracking

    var body: some View {
        Text(code)
            .font(FocusType.deviceCode)
            .tracking(Self.tracking)
            .textSelection(.enabled)
            // Tracking also follows the last letter; take it back so the code sits centred.
            .padding(.leading, FocusMetrics.deviceCodePadding.width)
            .padding(.trailing, FocusMetrics.deviceCodePadding.width - Self.tracking)
            .padding(.vertical, FocusMetrics.deviceCodePadding.height)
            .background(
                RoundedRectangle(cornerRadius: FocusMetrics.deviceCodeRadius, style: .continuous)
                    .fill(FocusColor.group)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FocusMetrics.deviceCodeRadius, style: .continuous)
                    .strokeBorder(FocusColor.separator, lineWidth: 1)
            )
            .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}

/// A large push button's title in the kit's 15 pt text, with its extra side padding. The
/// button itself stays the system's.
struct LargeButtonTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(FocusType.largeButton)
            .padding(.horizontal, FocusMetrics.largeButtonExtraPadding)
            .padding(.vertical, FocusMetrics.largeButtonExtraVerticalPadding)
    }
}
