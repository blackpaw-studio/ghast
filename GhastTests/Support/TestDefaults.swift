import Foundation
@testable import Ghast

/// A throwaway `UserDefaults` suite plus a closure that removes it.
struct IsolatedDefaults {
    let defaults: UserDefaults
    let cleanup: () -> Void
}

func makeIsolatedDefaults() -> IsolatedDefaults {
    let suiteName = "net.evancoleman.ghast.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return IsolatedDefaults(defaults: defaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A fresh, empty temporary directory.
func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ghast-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A `RunnerService` backed by an isolated defaults suite and an empty temp runners directory,
/// pre-seeded with `runners`. It never touches `UserDefaults.standard` or `~/.ghast/runners`.
@MainActor
func makeTestRunnerService(
    runners: [LocalRunner] = [],
    defaults: UserDefaults = makeIsolatedDefaults().defaults,
    runnersDirectory: URL = makeTemporaryDirectory()
) -> RunnerService {
    let service = RunnerService(defaults: defaults, runnersDirectory: runnersDirectory, scanner: NoRunnerProcessScanner())
    runners.forEach { service.addLocalRunner($0) }
    return service
}
