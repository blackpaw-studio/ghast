import Testing
import Foundation
@testable import Ghast

@MainActor @Suite("AppSettings")
struct AppSettingsTests {
    @Test("defaults restart runners, show the menu bar item and notify on unexpected stops only")
    func defaults() {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let settings = AppSettings(defaults: isolated.defaults)

        #expect(settings.restartRunnersAtLaunch)
        #expect(settings.showMenuBarExtra)
        #expect(settings.notifyUnexpectedStop)
        #expect(!settings.notifyJobFailure)
        #expect(!settings.notificationPermissionRequested)
    }

    @Test("changes persist to the injected defaults and survive a new instance")
    func persists() {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let settings = AppSettings(defaults: isolated.defaults)

        settings.restartRunnersAtLaunch = false
        settings.showMenuBarExtra = false
        settings.notifyUnexpectedStop = false
        settings.notifyJobFailure = true
        settings.notificationPermissionRequested = true

        let reloaded = AppSettings(defaults: isolated.defaults)
        #expect(!reloaded.restartRunnersAtLaunch)
        #expect(!reloaded.showMenuBarExtra)
        #expect(!reloaded.notifyUnexpectedStop)
        #expect(reloaded.notifyJobFailure)
        #expect(reloaded.notificationPermissionRequested)
    }

    @Test("an explicit false for a default-true setting is honoured, not treated as unset")
    func explicitFalse() {
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        isolated.defaults.set(false, forKey: AppSettings.Key.restartRunnersAtLaunch)

        #expect(!AppSettings(defaults: isolated.defaults).restartRunnersAtLaunch)
    }
}
