// Throwaway probe: does `screencapture -l` capture Liquid Glass at 2x with backdrop sampling?
//
// Shows a NavigationSplitView (sidebar, glass toolbar groups) in front of a full-screen window
// painted with high-contrast stripes, on the 1440 x 900 pt HiDPI display. If the sidebar glass
// samples its backdrop, the stripes appear blurred behind it.
//
// Prints:  probe-ready window=<n> backdrop=<n> rect=<x>,<y>,<w>,<h>
// where rect is the window's actual frame in global top-left display coordinates (for a region capture).
import SwiftUI
import AppKit

private let probeSize = CGSize(width: 1240, height: 780)
private let probeOrigin = CGPoint(x: 100, y: 60)

@main
struct GlassProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) var delegate

    var body: some Scene {
        Window("Glass Probe", id: "probe") {
            ProbeContent()
                .frame(width: probeSize.width, height: probeSize.height)
        }
        .windowResizability(.contentSize)
    }
}

struct ProbeContent: View {
    @State private var selection: Int? = 1

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("This Mac") {
                    ForEach(1...4, id: \.self) { index in
                        VStack(alignment: .leading) {
                            Text("runner-\(index)")
                            Text("Idle · org").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(index)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(248)
        } detail: {
            Text("Detail").font(.largeTitle).foregroundStyle(.secondary)
                .navigationTitle("runner-1")
                .navigationSubtitle("org · This Mac")
        }
        .toolbar {
            ToolbarItemGroup {
                Button { } label: { Image(systemName: "stop.fill") }
                Button { } label: { Image(systemName: "arrow.clockwise") }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { } label: { Image(systemName: "plus") }
            }
        }
    }
}

final class StripedView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let stripe: CGFloat = 24
        var x = -bounds.height
        var toggle = false
        while x < bounds.width {
            (toggle ? NSColor.black : NSColor.white).setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + stripe, y: 0))
            path.line(to: NSPoint(x: x + stripe + bounds.height, y: bounds.height))
            path.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
            path.close()
            path.fill()
            x += stripe
            toggle.toggle()
        }
    }
}

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var backdrop: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        let screen = NSScreen.screens.first { $0.frame.size == CGSize(width: 1440, height: 900) && $0.backingScaleFactor == 2 }
        guard let screen else {
            print("probe-error no 1440x900 @2x display attached")
            exit(3)
        }
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.contentView = StripedView()
        backdrop.setFrame(screen.frame, display: true)
        backdrop.orderBack(nil)
        self.backdrop = backdrop

        Task { @MainActor in
            for _ in 0..<300 {
                if let window = NSApp.windows.first(where: { $0 !== backdrop && $0.canBecomeMain && $0.isVisible }) {
                    await place(window, on: screen, backdrop: backdrop)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("probe-error no window appeared")
            exit(4)
        }
    }

    private func place(_ window: NSWindow, on screen: NSScreen, backdrop: NSWindow) async {
        let frame = CGRect(
            x: screen.frame.minX + probeOrigin.x,
            y: screen.frame.maxY - probeOrigin.y - probeSize.height,
            width: probeSize.width,
            height: probeSize.height
        )
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try? await Task.sleep(for: .seconds(1))
        // Report the window's real frame, not the requested one: SwiftUI sizes the window to its
        // content plus the title bar, so the two differ. Global top-left coordinates are
        // measured from the primary display's top edge.
        let actual = window.frame
        let primaryHeight = NSScreen.screens[0].frame.height
        let top = primaryHeight - actual.maxY
        print("probe-ready window=\(window.windowNumber) backdrop=\(backdrop.windowNumber) rect=\(Int(actual.minX)),\(Int(top)),\(Int(actual.width)),\(Int(actual.height))")
        fflush(stdout)
    }
}
