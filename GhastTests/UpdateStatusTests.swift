import Foundation
import Testing
@testable import Ghast

@MainActor
private final class FakeUpdater: UpdaterDriving {
    var automaticallyChecksForUpdates = true
    var lastUpdateCheckDate: Date?
    private(set) var backgroundChecks = 0

    func checkForUpdatesInBackground() { backgroundChecks += 1 }
}

@MainActor @Suite("Update status")
struct UpdateStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func make(lastCheck: Date? = nil) -> (UpdateStatusModel, FakeUpdater) {
        let updater = FakeUpdater()
        updater.lastUpdateCheckDate = lastCheck
        return (UpdateStatusModel(updater: updater), updater)
    }

    private func line(_ model: UpdateStatusModel) -> String {
        model.statusLine(now: now, locale: locale)
    }

    @Test("never checked")
    func neverChecked() {
        let (model, _) = make()
        #expect(line(model) == "Never checked")
        #expect(model.canCheckNow)
    }

    @Test("last checked, relative to now")
    func lastChecked() {
        let (model, _) = make(lastCheck: now.addingTimeInterval(-2 * 3600))
        #expect(line(model) == "Last checked 2 hours ago")
    }

    @Test("Check Now starts a background check and disables itself while checking")
    func checking() {
        let (model, updater) = make()

        model.checkNow()

        #expect(updater.backgroundChecks == 1)
        #expect(line(model) == "Checking…")
        #expect(!model.canCheckNow)
    }

    @Test("a check that finds nothing reads Up to date")
    func upToDate() {
        let (model, _) = make()
        model.checkNow()

        model.handle(.noUpdateFound)
        model.handle(.cycleFinished)

        #expect(line(model) == "Up to date")
        #expect(model.canCheckNow)
    }

    @Test("a check that finds an update reads Update available")
    func updateAvailable() {
        let (model, _) = make()
        model.checkNow()

        model.handle(.updateFound)
        model.handle(.cycleFinished)

        #expect(line(model) == "Update available")
    }

    @Test("a scheduled check that Ghast didn't start still updates the line")
    func scheduledCheck() {
        let (model, _) = make()
        model.handle(.noUpdateFound)
        #expect(line(model) == "Up to date")
    }

    @Test("a failed check falls back to when it last succeeded")
    func failed() {
        let (model, updater) = make(lastCheck: now.addingTimeInterval(-3 * 86400))
        model.checkNow()
        updater.lastUpdateCheckDate = now.addingTimeInterval(-3 * 86400)

        model.handle(.cycleFinished)

        #expect(line(model) == "Last checked 3 days ago")
        #expect(model.canCheckNow)
    }

    @Test("the automatic-check switch reads and writes Sparkle's setting")
    func automaticChecks() {
        let (model, updater) = make()
        model.automaticallyChecks = false
        #expect(!updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = true
        #expect(model.automaticallyChecks)
    }
}
