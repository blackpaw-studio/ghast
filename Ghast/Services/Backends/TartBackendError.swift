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

extension TartBackend {
    /// Whether another try, with a fresh VM, could succeed: a network or GitHub outage, a
    /// Tart command that failed, a VM that did not come up. Everything else (a missing group
    /// or image, a refused token, no Tart, the 2-VM limit) needs the user, so it ends the slot.
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? TartBackendError {
            switch error {
            case .bootTimedOut, .vmExitedDuringBoot: return true
            case .unavailable, .localImageMissing, .macOSVMLimit, .runnerGroupNotFound, .tooManyRunnerFailures: return false
            }
        }
        if error is TartError { return true }
        if let error = error as? URLError { return error.code != .cancelled }
        guard let error = error as? GitHubAPIError else { return false }
        switch error {
        case .serverError, .networkError, .invalidResponse, .rateLimited: return true
        case let .httpStatus(status): return status >= 500
        case .invalidURL, .noAccessToken, .unauthorized, .notFound, .decodingError, .notConfigured: return false
        }
    }
}
