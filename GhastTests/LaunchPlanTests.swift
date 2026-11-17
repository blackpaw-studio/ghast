import Testing
@testable import Ghast

@Suite("Launch plan")
struct LaunchPlanTests {
    @Test("a normal launch sets everything up")
    func normalLaunch() {
        #expect(LaunchPlan.make(isUnderTest: false) == LaunchPlan(
            checksSingleInstance: true,
            installsSignalHandlers: true,
            cleansUpRunnersOnQuit: true,
            startsServices: true,
            restartsRunners: true,
            showsMenuBarExtra: true
        ))
    }

    @Test("the XCTest host touches nothing of the user's: no services, restarts, status item, signal handlers or quit cleanup")
    func underTest() {
        #expect(LaunchPlan.make(isUnderTest: true) == LaunchPlan(
            checksSingleInstance: false,
            installsSignalHandlers: false,
            cleansUpRunnersOnQuit: false,
            startsServices: false,
            restartsRunners: false,
            showsMenuBarExtra: false
        ))
    }
}
