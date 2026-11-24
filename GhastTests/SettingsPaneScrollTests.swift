import AppKit
import SwiftUI
import Testing
@testable import Ghast

/// A Settings pane taller than its window (a laptop screen) scrolls, so nothing is cut off.
@Suite("Settings pane scrolling")
@MainActor
struct SettingsPaneScrollTests {
    private let contentHeight: CGFloat = 900
    private let windowHeight: CGFloat = 500

    @Test("a pane taller than the window scrolls to its last row")
    func tallPaneScrolls() async throws {
        let host = NSHostingView(rootView: SettingsPane { Color.clear.frame(height: contentHeight) })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: FocusMetrics.settingsWidth, height: windowHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        for _ in 0..<5 {
            await Task.yield()
            Self.spinRunLoop()
            window.layoutIfNeeded()
        }

        let scrollView = try #require(Self.scrollViews(in: host).first, "the pane has no scroll view")
        let document = try #require(scrollView.documentView)
        #expect(scrollView.contentView.bounds.height <= windowHeight)
        #expect(document.frame.height >= contentHeight)
    }

    @Test("a pane opens at its full height when the screen has room")
    func idealHeightFitsContent() {
        let host = NSHostingView(rootView: SettingsPane { Color.clear.frame(height: contentHeight) })
        #expect(host.fittingSize.height >= contentHeight)
    }

    /// Lets AppKit run one pass of pending layout.
    private static func spinRunLoop() { RunLoop.main.run(until: .now) }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
