import Foundation

/// Why a VM runner's slot could not run a job. Shown in the runner's log.
enum TartBackendError: LocalizedError, Equatable {
    case unavailable(TartInstallation)
    case localImageMissing(String)
    case macOSVMLimit
    case bootTimedOut(seconds: Int)
    case vmExitedDuringBoot
    case runnerGroupNotFound(String)
    case tooManyRunnerFailures(Int)

    var errorDescription: String? {
        switch self {
        case let .unavailable(installation):
            switch installation {
            case let .tooOld(_, version):
                "Tart \(version) is too old; \(TartLocator.minimumVersion) or later is required. Run: \(TartInstallation.reinstallCommand)"
            case .found, .missing:
                "Tart is not installed. Run: \(TartInstallation.installCommand)"
            }
        case let .localImageMissing(name):
            "No local Tart VM named \"\(name)\" exists."
        case .macOSVMLimit:
            "macOS allows at most 2 virtual machines to run at once, and 2 already are. Stop one, then start this runner again."
        case let .bootTimedOut(seconds):
            "The VM did not accept commands within \(seconds) s. Custom images must include the Tart Guest Agent."
        case .vmExitedDuringBoot:
            "The VM stopped while it was starting."
        case let .runnerGroupNotFound(name):
            "Runner group \"\(name)\" does not exist in this organization."
        case let .tooManyRunnerFailures(count):
            "The runner failed \(count) times in a row, so the slot stopped. Check the output."
        }
    }
}
