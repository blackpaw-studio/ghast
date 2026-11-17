import Foundation
import Sparkle

extension SPUUpdater: UpdaterDriving {}

/// Sparkle's delegate, turned into `UpdaterEvent`s for Settings. Sparkle calls it on the main
/// thread; it is created before the updater, so its consumer is attached later.
final class SparkleUpdateEvents: NSObject, SPUUpdaterDelegate {
    @MainActor var onEvent: ((UpdaterEvent) -> Void)?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        send(.updateFound)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        send(.noUpdateFound)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        send(.cycleFinished)
    }

    private func send(_ event: UpdaterEvent) {
        MainActor.assumeIsolated { onEvent?(event) }
    }
}
