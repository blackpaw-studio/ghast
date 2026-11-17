#if DEBUG
import Testing
import Foundation
@testable import Ghast

@Suite("FixtureLaunch")
struct FixtureLaunchTests {
    @Test("no fixture flag means a normal launch")
    func absentFlag() throws {
        #expect(try FixtureLaunch.parse(["Ghast", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test("parses the screen, light by default")
    func screenOnly() throws {
        let launch = try FixtureLaunch.parse(["Ghast", "-GhastDesignFixture", "error"])
        #expect(launch == FixtureLaunch(screen: .error, isDark: false))
    }

    @Test("parses dark appearance")
    func dark() throws {
        let launch = try FixtureLaunch.parse(["Ghast", "-GhastDesignFixture", "menu-bar", "-GhastAppearance", "dark"])
        #expect(launch == FixtureLaunch(screen: .menuBar, isDark: true))
    }

    @Test("every one of the 12 mockup screens, plus New Runner's busy-account states, has a name")
    func twelveScreens() {
        #expect(FixtureScreen.allCases.map(\.rawValue) == [
            "main", "configuration", "remote", "error", "first-run", "welcome", "device-code",
            "new-runner", "new-runner-progress", "new-runner-loading", "new-runner-loaded", "settings-general", "settings-account", "menu-bar",
        ])
    }

    @Test("an unknown screen is an error, never a silent real launch")
    func unknownScreen() {
        #expect(throws: FixtureLaunchError.unknownScreen("nope")) {
            try FixtureLaunch.parse(["Ghast", "-GhastDesignFixture", "nope"])
        }
    }

    @Test("a missing screen name is an error")
    func missingScreen() {
        #expect(throws: FixtureLaunchError.missingScreen) {
            try FixtureLaunch.parse(["Ghast", "-GhastDesignFixture"])
        }
    }

    @Test("an unknown appearance is an error")
    func unknownAppearance() {
        #expect(throws: FixtureLaunchError.unknownAppearance("sepia")) {
            try FixtureLaunch.parse(["Ghast", "-GhastDesignFixture", "main", "-GhastAppearance", "sepia"])
        }
    }

    @Test("the main window sits at the mockup offset on a 1440 x 900 pt screen")
    func mainPlacement() throws {
        let placement = try #require(FixtureScreen.main.placement)
        #expect(placement.size == CGSize(width: 1240, height: 780))
        #expect(placement.topLeft == CGPoint(x: 100, y: 60))
        let frame = placement.frame(onScreen: CGRect(x: 1440, y: 0, width: 1440, height: 900))
        #expect(frame == CGRect(x: 1540, y: 60, width: 1240, height: 780))
    }

    @Test("the menu bar screen has no window to place")
    func menuBarHasNoWindow() {
        #expect(FixtureScreen.menuBar.placement == nil)
    }
}
#endif
