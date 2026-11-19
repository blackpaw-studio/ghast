import Foundation

/// Why a VM runner could not run a job. Shown in the runner's log.
enum TartBackendError: LocalizedError, Equatable {
    case unavailable(TartInstallation)
    case localImageMissing(String)
    case bootTimedOut(seconds: Int)
    case vmExitedDuringBoot
    case runnerGroupNotFound(String)
    /// The guest's runner exited with a non-zero code.
    case runnerExited(Int32)
    /// GitHub's runner scale-set service refused the token for an organization runner,
    /// which has no REST fallback.
    case scaleSetAuthRejected

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
        case let .bootTimedOut(seconds):
            "The VM did not accept commands within \(seconds) s. Custom images must include the Tart Guest Agent."
        case .vmExitedDuringBoot:
            "The VM stopped while it was starting."
        case let .runnerGroupNotFound(name):
            "Runner group \"\(name)\" does not exist in this organization."
        case let .runnerExited(code):
            "The runner exited with code \(code)."
        case .scaleSetAuthRejected:
            "GitHub did not let Ghast manage runner scale sets for this organization. Sign out and in again, or check that you own the organization."
        }
    }
}

extension TartBackend {
    /// Whether another try, with a fresh VM, could succeed: a network or GitHub outage, a
    /// Tart command that failed, a VM that did not come up, a runner that exited with an
    /// error, a scale-set session another listener still holds. Everything else (a missing
    /// group or image, a refused token, no Tart) needs the user, so it ends the runner.
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? TartBackendError {
            switch error {
            case .bootTimedOut, .vmExitedDuringBoot, .runnerExited: return true
            case .unavailable, .localImageMissing, .runnerGroupNotFound, .scaleSetAuthRejected: return false
            }
        }
        if let error = error as? ScaleSetError {
            switch error {
            case .transient, .rateLimited, .conflict: return true
            case .authRejected, .notFound, .badRequest, .badResponse: return false
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
