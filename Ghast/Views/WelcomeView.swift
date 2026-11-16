import SwiftUI
import AppKit

/// The signed-out window (Welcome.png, left): app icon, three feature rows and Sign In.
struct WelcomeView: View {
    /// The last attempt's error, shown under the button, which then reads Try Again.
    let failure: DeviceFlowError?
    let signIn: () -> Void

    private static let features: [(glyph: String, title: String, detail: String)] = [
        ("laptopcomputer", "Your Mac, your runners", "Ghast downloads, registers and runs the official GitHub runner."),
        ("terminal", "Live output", "Watch each job as it runs, with status at a glance."),
        ("rectangle.inset.bottomright.filled", "Stays out of the way", "Runners keep working from the menu bar."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // The icon's artwork fills 824 of its 1024 pt canvas: scale the canvas so the
            // squircle itself is the kit's 96 pt, without moving anything around it.
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: FocusMetrics.appIconCanvas, height: FocusMetrics.appIconCanvas)
                .frame(width: FocusMetrics.appIconLarge, height: FocusMetrics.appIconLarge)
                .accessibilityHidden(true)
                .padding(.top, FocusMetrics.welcomeIconTop)
            Text("Welcome to Ghast")
                .font(FocusType.largeTitle)
                .padding(.top, FocusMetrics.welcomeIconGap)
            Text("Run GitHub Actions jobs on this Mac.")
                .font(FocusType.title3.weight(.regular))
                .foregroundStyle(.secondary)
                .padding(.top, FocusMetrics.welcomeTitleGap)
            VStack(alignment: .leading, spacing: FocusMetrics.welcomeFeatureSpacing) {
                ForEach(Self.features, id: \.title) { feature in
                    FeatureRow(glyph: feature.glyph, title: feature.title, detail: feature.detail)
                }
            }
            .frame(width: FocusMetrics.welcomeFeatureColumn, alignment: .leading)
            .padding(.top, FocusMetrics.welcomeFeaturesTop)
            Button(action: signIn) { LargeButtonTitle(failure == nil ? "Sign In with GitHub" : "Try Again") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, FocusMetrics.welcomeButtonTop)
            if let failure {
                Text(failure.userMessage)
                    .font(FocusType.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: FocusMetrics.welcomeFeatureColumn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FocusMetrics.welcomeFailureGap)
            }
            Text("Ghast asks for access to your repositories and organization runners.")
                .font(FocusType.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, FocusMetrics.welcomeFootnoteGap)
            Spacer(minLength: 0)
        }
        .frame(width: FocusMetrics.welcomeWindow.width, height: FocusMetrics.welcomeWindow.height)
    }
}

/// A 32 pt accent glyph beside a Headline title and a Callout line.
private struct FeatureRow: View {
    let glyph: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: FocusMetrics.welcomeFeatureGlyphGap) {
            Image(systemName: glyph)
                .font(.system(size: FocusMetrics.welcomeFeatureGlyph * 0.75, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: FocusMetrics.welcomeFeatureGlyph, height: FocusMetrics.welcomeFeatureGlyph)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FocusMetrics.welcomeFeatureTextGap) {
                Text(title).font(FocusType.headline)
                Text(detail)
                    .font(FocusType.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Welcome") {
    WelcomeView(failure: nil, signIn: {})
}
