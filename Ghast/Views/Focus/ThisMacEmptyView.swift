import SwiftUI

/// No runners on this Mac yet: what Ghast does and how to start.
struct ThisMacEmptyView: View {
    let newRunner: () -> Void
    @Environment(\.openURL) private var openURL

    static let aboutRunnersURL = URL(string: "https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners")!

    var body: some View {
        VStack(spacing: 0) {
            LaptopPlusGlyph()
                .padding(.bottom, FocusMetrics.emptyGlyphGap)
            Text("No Runners on This Mac")
                .font(FocusType.title1)
                .padding(.bottom, FocusMetrics.emptyTitleGap)
            // Broken by hand to match the mockup's balanced lines.
            Text("Create a runner for a repository or organization.\nGhast downloads the official GitHub\nrunner, registers it, and starts it for you.")
                .font(FocusType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: FocusMetrics.emptyStateBodyMaxWidth)
                .padding(.bottom, FocusMetrics.emptyButtonGap)
            Button("New Runner…", action: newRunner)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .padding(.bottom, FocusMetrics.emptyLinkGap)
            Button("About Self-Hosted Runners") { openURL(Self.aboutRunnersURL) }
                .buttonStyle(.link)
                .font(FocusType.body)
        }
        .offset(y: FocusMetrics.emptyStateLift)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusContentLayer()
    }
}

/// A laptop with a plus on its screen. The system set has no such symbol, so it is two.
private struct LaptopPlusGlyph: View {
    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: FocusMetrics.emptyStateGlyph, weight: .light))
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: FocusMetrics.emptyStatePlus, weight: .medium))
                    .offset(y: FocusMetrics.emptyStatePlusOffset)
            }
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// Below a remote runner's header: there is no output to show here.
struct RemoteOutputNote: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "apple.terminal")
                .font(.system(size: FocusMetrics.remoteNoteGlyph, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.bottom, FocusMetrics.remoteNoteGlyphGap)
            Text("Output Is on That Machine")
                .font(FocusType.title3)
                .padding(.bottom, FocusMetrics.remoteNoteTitleGap)
            Text("Ghast shows live output only for runners on this Mac.")
                .font(FocusType.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .offset(y: FocusMetrics.remoteNoteLift)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
