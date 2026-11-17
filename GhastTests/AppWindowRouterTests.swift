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
}
