import Testing
import Foundation
@testable import Ghast

@MainActor @Suite("CacheSettingsModel")
struct CacheSettingsModelTests {
    private func make(_ stats: FakeCacheStats = FakeCacheStats()) -> (CacheSettingsModel, AppSettings, FakeCacheStats) {
        let settings = AppSettings(defaults: makeIsolatedDefaults().defaults)
        return (CacheSettingsModel(stats: stats, settings: settings), settings, stats)
    }

    @Test("a new cap is saved and applied at once, which evicts")
    func capEvicts() async {
        let (model, settings, stats) = make()

        await model.applyCap(20)
        await model.applyCap(0)

        #expect(stats.calls == ["setCap 20", "setCap 1"])
        #expect(settings.cacheSizeCapGB == 1)
        #expect(model.capGB == 1)
    }

    @Test("clearing happens only after the confirmation is shown, and refreshes the space used")
    func clearNeedsConfirmation() async {
        let stats = FakeCacheStats()
        stats.currentUsage = CacheUsage(entryCount: 3, totalBytes: 2_000_000_000, pendingUploads: 0)
        let (model, _, _) = make(stats)
        await model.refresh()

        await model.confirmClear()
        #expect(stats.calls.isEmpty)

        model.requestClear()
        #expect(model.isShowingClearConfirmation)
        // SwiftUI dismisses the dialog before the button's action runs.
        model.isShowingClearConfirmation = false
        await model.confirmClear()

        #expect(stats.calls == ["clear"])
        #expect(model.usageText == "Empty")
        await model.confirmClear()
        #expect(stats.calls == ["clear"])
    }

    @Test("cancelling the confirmation clears nothing")
    func cancelClear() async {
        let (model, _, stats) = make()

        model.requestClear()
        model.isShowingClearConfirmation = false
        model.cancelClear()
        await model.confirmClear()

        #expect(stats.calls.isEmpty)
    }

    @Test("space used reads as size and count, singular for one, and Checking before the first read",
          arguments: [
              (nil, "Checking…"),
              (CacheUsage(entryCount: 0, totalBytes: 0, pendingUploads: 0), "Empty"),
              (CacheUsage(entryCount: 1, totalBytes: 512_000_000, pendingUploads: 0), "512 MB in 1 cache"),
              (CacheUsage(entryCount: 42, totalBytes: 18_400_000_000, pendingUploads: 0), "18.4 GB in 42 caches"),
          ] as [(CacheUsage?, String)])
    func usageText(usage: CacheUsage?, expected: String) {
        #expect(CacheSettingsModel.usageText(usage) == expected)
    }

    @Test("a failed change shows why, and the next success clears it")
    func failureMessage() async {
        let stats = FakeCacheStats()
        stats.failure = FakeCacheStats.Failure()
        let (model, _, _) = make(stats)

        await model.applyCap(10)
        #expect(model.errorMessage == "Ghast couldn’t apply the size cap: the disk is full")

        stats.failure = nil
        await model.applyCap(10)
        #expect(model.errorMessage == nil)
    }
}
