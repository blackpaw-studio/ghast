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
    /// The image's disk won't fit in the free space; Tart's pull would fail or auto-prune.
    case insufficientSpace(image: String, neededBytes: Int64, freeBytes: Int64)

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
        case let .insufficientSpace(image, needed, free):
            "Not enough disk space to pull \(TartImageRef.shortName(of: image)): needs about \(Self.gigabytes(needed, roundingUp: true)) GB, \(Self.gigabytes(free, roundingUp: false)) GB free. Free space in Settings › General › Tart Storage."
        case .scaleSetAuthRejected:
            "GitHub did not let Ghast manage runner scale sets for this organization. Sign out and in again, or check that you own the organization."
        }
    }

    private static func gigabytes(_ bytes: Int64, roundingUp: Bool) -> Int64 {
        let unit: Int64 = 1_000_000_000
        return roundingUp ? (bytes + unit - 1) / unit : bytes / unit
    }
}

extension TartBackend {
    /// The reason a failed runner must not be retried, if the failure has one.
    nonisolated static func exitBlock(for failure: (any Error)?) -> RunnerExitBlock? {
        guard case let .insufficientSpace(image, _, _)? = failure as? TartBackendError else { return nil }
        return .insufficientDiskSpace(image: image)
    }

    /// How long the server asked Ghast to wait before trying again, if it did.
    nonisolated static func retryAfter(_ error: any Error) -> Duration? {
        if let error = error as? DemandSourceError { return retryAfter(error.underlying) }
        if case let .rateLimited(seconds?)? = error as? ScaleSetError { return .seconds(seconds) }
        return nil
    }

    /// Whether another try, with a fresh VM, could succeed: a network or GitHub outage, a
    /// Tart command that failed, a VM that did not come up, a runner that exited with an
    /// error, a scale-set session another listener still holds. Everything else (a missing
    /// group or image, a refused token, no Tart) needs the user, so it ends the runner.
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        if error is DemandSourceError { return true }
        if let error = error as? TartBackendError {
            switch error {
            case .bootTimedOut, .vmExitedDuringBoot, .runnerExited: return true
            case .unavailable, .localImageMissing, .runnerGroupNotFound, .scaleSetAuthRejected, .insufficientSpace: return false
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
