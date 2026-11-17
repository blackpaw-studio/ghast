import AppKit
import Testing
@testable import Ghast

/// Before any window has appeared (a login launch with the main window closed), the router has
/// no SwiftUI open action; it must still open the main window.
@MainActor
@Suite("App window router")
struct AppWindowRouterTests {
    @MainActor final class Log { var entries: [String] = [] }

    private func makeRouter(_ log: Log) -> AppWindowRouter {
        AppWindowRouter(
            activate: { log.entries.append("activate") },
            openMainWithoutWindow: { log.entries.append("open main through the app") }
        )
    }

    @Test("Open Ghast with no window ever shown opens the main window through the app")
    func openMainWithoutWindow() {
        let log = Log()

        makeRouter(log).openMain()

        #expect(log.entries == ["activate", "open main through the app"])
    }

    @Test("New Runner… and a notification click with no window ever shown open the main window, keeping their request")
    func requestsWithoutWindow() {
        let log = Log()
        let router = makeRouter(log)

        router.newRunner()
        router.showOutput(runnerID: "r1")

        #expect(log.entries.filter { $0 == "open main through the app" }.count == 2)
        #expect(router.newRunnerRequest != nil)
        #expect(router.showOutputRequest?.runnerID == "r1")
    }

    @Test("the main scene's Window menu item is titled mainWindowTitle, the item the no-window fallback chooses")
    func mainWindowMenuItemMatchesTitle() throws {
        // The test host is Ghast itself, so its Window menu lists the real scenes.
        let menu = try #require(NSApp.windowsMenu)
        #expect(menu.items.contains { $0.title == GhastApp.mainWindowTitle && $0.action != nil })
    }
}
