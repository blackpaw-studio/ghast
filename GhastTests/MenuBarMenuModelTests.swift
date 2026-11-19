import Foundation
import Testing
@testable import Ghast

@Suite("Menu bar menu")
struct MenuBarMenuModelTests {
    private static let scope = RunnerScope.organization(login: "blackpaw-studio")
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func local(_ name: String, _ status: RunnerDisplayStatus) -> RunnerItem {
        RunnerItem(id: "id-\(name)", name: name, scope: Self.scope, labels: [], location: .thisMac(localID: "id-\(name)"), gitHubRunnerID: nil, status: status)
    }

    private let runningSubmenu: [MenuBarSubmenuItem] = [.showOutput, .separator, .restart, .stop]
    private let stoppedSubmenu: [MenuBarSubmenuItem] = [.showOutput, .separator, .start]

    @Test("lists the runners on this Mac with dots, short status words and submenus, then the commands")
    func fullMenu() {
        let menu = MenuBarMenuModel.make(
            runners: [
                local("dionysus-arm64", .idle),
                local("dionysus-xcode", .runningJob(name: "build", since: nil)),
                local("ghast-release", .error(code: 1, at: Self.now)),
            ],
            isSignedIn: true
        )

        #expect(menu == [
            .sectionHeader("This Mac"),
            .runner(MenuBarRunnerEntry(id: "id-dionysus-arm64", name: "dionysus-arm64", dot: .idle, badge: "Idle", submenu: runningSubmenu)),
            .runner(MenuBarRunnerEntry(id: "id-dionysus-xcode", name: "dionysus-xcode", dot: .running, badge: "Running", submenu: runningSubmenu)),
            .runner(MenuBarRunnerEntry(id: "id-ghast-release", name: "ghast-release", dot: .error, badge: "Exited", submenu: stoppedSubmenu)),
            .separator,
            .command(.startAll, isEnabled: true),
            .command(.stopAll, isEnabled: true),
            .separator,
            .command(.newRunner, isEnabled: true),
            .command(.openGhast, isEnabled: true),
            .separator,
            .command(.settings, isEnabled: true),
            .command(.quit, isEnabled: true),
        ])
    }

    @Test("each status has its dot, word and submenu", arguments: [
        (RunnerDisplayStatus.idle, MenuBarDot.idle, "Idle", true),
        (.runningJob(name: "build", since: nil), .running, "Running", true),
        (.starting, .hollow, "Connecting", true),
        (.pulling(.indeterminate), .hollow, "Pulling", true),
        (.pulling(TartPullProgress(fraction: 0.42, size: "27.0 GB")), .hollow, "Pulling 42%", true),
        (.booting, .hollow, "Booting", true),
        (.cleaningUp, .hollow, "Cleaning up", true),
        (.onDemand(.waitingForJobs), .idle, "Waiting", true),
        (.onDemand(.booting), .hollow, "Booting", true),
        (.onDemand(.running(2)), .running, "Running", true),
        (.onDemand(.waitingForSlot), .hollow, "No VM slot", true),
        (.stopping, .hollow, "Stopping", false),
        (.stopped(at: nil), .hollow, "Stopped", false),
        (.error(code: 1, at: now), .error, "Exited", false),
    ])
    func statusWords(status: RunnerDisplayStatus, dot: MenuBarDot, badge: String, isRunning: Bool) {
        let menu = MenuBarMenuModel.make(runners: [local("r", status)], isSignedIn: true)
        guard case let .runner(entry)? = menu.dropFirst().first else {
            Issue.record("expected a runner entry second, got \(menu)")
            return
        }
        #expect(entry.dot == dot)
        #expect(entry.badge == badge)
        #expect(entry.submenu == (isRunning ? runningSubmenu : stoppedSubmenu))
    }

    @Test("Start All is off when everything runs; Stop All is off when nothing does")
    func startStopAll() {
        let allRunning = MenuBarMenuModel.make(runners: [local("a", .idle), local("b", .starting)], isSignedIn: true)
        #expect(allRunning.contains(.command(.startAll, isEnabled: false)))
        #expect(allRunning.contains(.command(.stopAll, isEnabled: true)))

        let noneRunning = MenuBarMenuModel.make(runners: [local("a", .stopped(at: nil)), local("b", .error(code: 1, at: Self.now))], isSignedIn: true)
        #expect(noneRunning.contains(.command(.startAll, isEnabled: true)))
        #expect(noneRunning.contains(.command(.stopAll, isEnabled: false)))
    }

    @Test("a runner that Remove or Reconfigure is working on can't be started, stopped or restarted")
    func busyRunner() {
        let menu = MenuBarMenuModel.make(runners: [local("a", .idle), local("b", .idle)], isSignedIn: true, busyRunnerIDs: ["id-a"])
        let controllable = menu.compactMap { entry -> Bool? in
            if case let .runner(runner) = entry { return runner.canControl }
            return nil
        }
        #expect(controllable == [false, true])
    }

    @Test("a stopping runner can't be started, stopped or restarted until it has ended")
    func stoppingRunner() {
        let menu = MenuBarMenuModel.make(runners: [local("a", .stopping), local("b", .idle)], isSignedIn: true)
        let controllable = menu.compactMap { entry -> Bool? in
            if case let .runner(runner) = entry { return runner.canControl }
            return nil
        }
        #expect(controllable == [false, true])
    }

    @Test("signed out: runners stay controllable, New Runner is off")
    func signedOut() {
        let menu = MenuBarMenuModel.make(runners: [local("a", .idle)], isSignedIn: false)
        #expect(menu.contains(.command(.newRunner, isEnabled: false)))
        #expect(menu.contains(.command(.stopAll, isEnabled: true)))
        #expect(menu.contains(.command(.openGhast, isEnabled: true)))
    }

    @Test("no runners: a disabled No runners on this Mac item and nothing to start or stop")
    func empty() {
        let menu = MenuBarMenuModel.make(runners: [], isSignedIn: true)
        #expect(Array(menu.prefix(3)) == [.sectionHeader("This Mac"), .placeholder("No runners on this Mac"), .separator])
        #expect(menu.contains(.command(.startAll, isEnabled: false)))
        #expect(menu.contains(.command(.stopAll, isEnabled: false)))
    }
}
