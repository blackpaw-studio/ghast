#if DEBUG
import AppKit
import Foundation

/// Sets the scene for a capture: forces the appearance, paints the kit's desk backdrop, moves
/// the app's window to the mockup offset and prints `fixture-ready window=<number>` once
/// layout has settled.
@MainActor
final class FixtureStage {
    static let readyPrefix = "fixture-ready"
    private static let pollInterval: Duration = .milliseconds(100)
    private static let readyTimeout: Duration = .seconds(30)
    private static let stableLayoutPolls = 3

    private let launch: FixtureLaunch
    private let emit: @MainActor (String) -> Void
    private let removeScratch: @MainActor () -> Void
    private let prepare: @MainActor () async -> Void
    private var backdrop: NSWindow?
    private var task: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []

    /// - Parameter removeScratch: Deletes the fixture's throwaway storage; runs on quit and on
    ///   SIGTERM/SIGINT, because a fixture is always stopped by the capture script.
    ///   - prepare: Runs before the window is announced, so a capture never sees half-seeded state.
    init(
        launch: FixtureLaunch,
        emit: @escaping @MainActor (String) -> Void = FixtureStage.printToStdout,
        removeScratch: @escaping @MainActor () -> Void = {},
        prepare: @escaping @MainActor () async -> Void = {}
    ) {
        self.launch = launch
        self.emit = emit
        self.removeScratch = removeScratch
        self.prepare = prepare
    }

    func shutdown() {
        removeScratch()
    }

    private func installTerminationHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    static func printToStdout(_ line: String) {
        print(line)
        fflush(stdout)
    }

    func start() {
        installTerminationHandlers()
        NSApp.appearance = NSAppearance(named: launch.isDark ? .darkAqua : .aqua)
        let screen = Self.targetScreen()
        backdrop = makeBackdrop(on: screen)
        task = Task { [weak self] in
            await self?.prepare()
            await self?.placeWindowAndAnnounce(on: screen)
        }
    }

    /// The 1440 x 900 pt HiDPI screen if one is attached (the virtual display); otherwise the
    /// main screen, which only the pipeline check can use.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.frame.size == FixtureWindowPlacement.screenSize && $0.backingScaleFactor == 2
        } ?? NSScreen.main
    }

    // MARK: - Backdrop

    private func makeBackdrop(on screen: NSScreen?) -> NSWindow? {
        guard let screen else { return nil }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.contentView = DeskBackdropView(isDark: launch.isDark)
        window.setFrame(screen.frame, display: true)
        window.orderBack(nil)
        return window
    }

    // MARK: - Placement

    private func placeWindowAndAnnounce(on screen: NSScreen?) async {
        guard let placement = launch.screen.placement else {
            emit("\(Self.readyPrefix) window=0 rect=0,0,1440,900")
            return
        }
        guard let window = await waitForContentWindow() else {
            emit("fixture-error no window appeared within 30 s")
            return
        }
        if let screen {
            window.setFrame(placement.frame(onScreen: screen.frame), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        await waitForStableLayout(of: window)
        // The window's real frame: a window can end up larger than requested (title bar, content
        // minimums), and the compare script crops the mockup to exactly this rect.
        let frame = window.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        let rect = [frame.minX, primaryHeight - frame.maxY, frame.width, frame.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
        emit("\(Self.readyPrefix) window=\(window.windowNumber) rect=\(rect)")
    }

    private func waitForContentWindow() async -> NSWindow? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.readyTimeout)
        while clock.now < deadline {
            if let window = NSApp.windows.first(where: { $0 !== backdrop && $0.canBecomeMain && $0.isVisible }) {
                return window
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return nil
    }

    private func waitForStableLayout(of window: NSWindow) async {
        var stable = 0
        while stable < Self.stableLayoutPolls {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            stable = (window.contentView?.needsLayout ?? false) ? 0 : stable + 1
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

/// The kit's `--desk` gradient (not shipped: lives in the DEBUG fixture).
private final class DeskBackdropView: NSView {
    init(isDark: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = (isDark ? Self.darkStops : Self.lightStops).map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer = gradient
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let lightStops = [NSColor(hex: 0xDDE3EC), NSColor(hex: 0xCBD3DF)]
    private static let darkStops = [NSColor(hex: 0x232730), NSColor(hex: 0x14171D)]
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
