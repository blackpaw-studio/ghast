// Throwaway probe: does a Peekaboo capture of an active Liquid Glass window come out at 2x with
// the glass sampling its own content?
//
// Shows a NavigationSplitView (inset sidebar, glass toolbar capsules) whose detail area is a tall
// scroll view of high-contrast stripes, scrolled so they pass under a toolbar capsule. macOS 26
// glass samples the window's own content under it (not windows behind it), so the capsule should
// show those stripes blurred. A full-screen striped window sits behind it only to give the
// window a busy desktop.
//
// Prints:  probe-ready window=<n> backdrop=<n> rect=<x>,<y>,<w>,<h> capsule=<x>,<y>,<w>,<h>
//          active=<0|1> key=<0|1> pid=<pid>
// rect is the window's actual frame in global top-left display coordinates (for a region
// capture); capsule is the probe capsule's content frame in points from the window's top-left.
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

/// Where the probe capsule's content sits, in points from the window's top-left. Set by the view.
@MainActor var probeCapsuleFrame = CGRect.zero

/// High-contrast diagonal stripes, tall enough to scroll.
struct StripesView: View {
    var body: some View {
        Canvas { context, size in
            let stripe: CGFloat = 24
            var x = -size.height
            var dark = false
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + stripe, y: 0))
                path.addLine(to: CGPoint(x: x + stripe + size.height, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(dark ? .black : .white))
                x += stripe
                dark.toggle()
            }
        }
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
            // Stripes run under the toolbar: the content scrolls beneath the glass capsules.
            ScrollView {
                StripesView().frame(height: 4000)
            }
            .defaultScrollAnchor(.center)
            .ignoresSafeArea(.container, edges: .top)
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
                // An icon-free capsule, so the glass over the stripes is measured on its own.
                Color.clear
                    .frame(width: 90, height: 20)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeCapsuleFrame = $0 }
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
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .seconds(1.5))
        // Report the window's real frame, not the requested one: SwiftUI sizes the window to its
        // content plus the title bar, so the two differ. Global top-left coordinates are
        // measured from the primary display's top edge.
        let actual = window.frame
        let primaryHeight = NSScreen.screens[0].frame.height
        let top = primaryHeight - actual.maxY
        let capsule = probeCapsuleFrame
        let capsuleText = [capsule.minX, capsule.minY, capsule.width, capsule.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        print("probe-ready window=\(window.windowNumber) backdrop=\(backdrop.windowNumber) rect=\(Int(actual.minX)),\(Int(top)),\(Int(actual.width)),\(Int(actual.height)) capsule=\(capsuleText) active=\(NSApp.isActive ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0) pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
    }
}
