import Foundation

/// What a normal launch sets up. The XCTest host is this app with the user's real defaults and
/// runners on the same machine, so under test it sets up none of it: no services tailing real
/// runner output, no system notifications, no restarts, no status item, and no quit cleanup
/// (which `pkill`s runner processes machine-wide).
struct LaunchPlan: Equatable {
    var checksSingleInstance: Bool
    var installsSignalHandlers: Bool
    var cleansUpRunnersOnQuit: Bool
    var startsServices: Bool
    var restartsRunners: Bool
    var showsMenuBarExtra: Bool

    static func make(isUnderTest: Bool) -> LaunchPlan {
        LaunchPlan(
            checksSingleInstance: !isUnderTest,
            installsSignalHandlers: !isUnderTest,
            cleansUpRunnersOnQuit: !isUnderTest,
            startsServices: !isUnderTest,
            restartsRunners: !isUnderTest,
            showsMenuBarExtra: !isUnderTest
        )
    }
}
