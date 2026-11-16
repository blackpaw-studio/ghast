import Foundation
import Observation
import os

/// GitHub's view of every scope Ghast cares about (admin orgs plus the scopes of this Mac's
/// runners), refreshed on the `RefreshScheduler`'s rules. Feeds `RunnerCatalog.merge`.
@MainActor
@Observable
final class RemoteRunnerStore {
    /// Each scope's latest fetch. A scope that needs owner access has no entry.
    private(set) var fetches: [RunnerScope: RemoteFetch] = [:]
    /// Organizations whose runners GitHub refused (403/404): listed in Settings › Account.
    private(set) var needsOwnerAccess: Set<String> = []
    private(set) var adminOrganizations: [GitHubOrganization] = []
    /// Set by the main window: polls run only while it is visible and not occluded.
    var isVisible = true

    @ObservationIgnored private var scheduler = RefreshScheduler()
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private let api: any GitHubAPIServiceProtocol
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let localScopes: @MainActor () -> [RunnerScope]
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "remote-runners")

    init(api: any GitHubAPIServiceProtocol, clock: any AppClock, localScopes: @escaping @MainActor () -> [RunnerScope]) {
        self.api = api
        self.clock = clock
        self.localScopes = localScopes
    }

    /// Refreshes every scope if the scheduler allows `trigger` now.
    func refresh(_ trigger: RefreshScheduler.Trigger) async {
        let now = clock.now()
        guard !isRefreshing, scheduler.shouldRefresh(trigger, now: now, isVisible: isVisible) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        scheduler.didStart(at: now)

        var failures: [Error] = []
        do {
            adminOrganizations = try await api.fetchAdminOrganizations()
        } catch {
            // Keep the organizations from the last good fetch.
            if !error.isCancellation { failures.append(error) }
        }

        let scopes = Set(adminOrganizations.map { RunnerScope.organization(login: $0.login) } + localScopes())
        var next: [RunnerScope: RemoteFetch] = [:]
        for scope in scopes.sorted(by: { $0.displayName < $1.displayName }) {
            do {
                next[scope] = .loaded(try await api.fetchRunners(in: scope), at: clock.now())
                if case let .organization(login) = scope { needsOwnerAccess.remove(login) }
            } catch {
                if error.isCancellation { return }
                if case let .organization(login) = scope, Self.needsOwnerAccess(error) {
                    needsOwnerAccess.insert(login)
                    continue
                }
                Self.logger.error("Couldn't list runners for \(scope.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                next[scope] = .failed(error, lastGood: Self.lastGood(fetches[scope]))
                failures.append(error)
            }
        }
        fetches = next
        record(failures, now: clock.now())
    }

    /// Polls for as long as the calling task lives, waking when the next poll is due.
    func pollWhileAlive(sleeper: Sleeper) async {
        while !Task.isCancelled {
            let due = scheduler.nextPollDate() ?? clock.now().addingTimeInterval(RefreshScheduler.pollInterval)
            let wait = max(Self.minimumPollWait, due.timeIntervalSince(clock.now()))
            do { try await sleeper(.seconds(wait)) } catch { return }
            await refresh(.poll)
        }
    }

    // MARK: -

    /// Never poll faster than this, whatever the scheduler says.
    private static let minimumPollWait: TimeInterval = 1

    private func record(_ failures: [Error], now: Date) {
        // Backoff is for GitHub being unreachable or limiting us, not for one scope's 4xx.
        let transient = failures.compactMap { $0 as? GitHubAPIError }.filter(\.isTransient)
            + failures.filter { !($0 is GitHubAPIError) }.map { GitHubAPIError.networkError($0) }
        guard !transient.isEmpty else {
            scheduler.didSucceed()
            return
        }
        scheduler.didFail(retryAt: transient.compactMap { $0.retryDate(now: now) }.max())
    }

    private static func needsOwnerAccess(_ error: Error) -> Bool {
        switch error as? GitHubAPIError {
        case .httpStatus(403)?, .notFound?: return true
        default: return false
        }
    }

    private static func lastGood(_ fetch: RemoteFetch?) -> LoadedRunners? {
        switch fetch {
        case let .loaded(runners, at)?: return LoadedRunners(runners: runners, at: at)
        case let .failed(_, lastGood)?: return lastGood
        case nil: return nil
        }
    }
}

private extension GitHubAPIError {
    /// Worth backing off for: the network, GitHub's servers, or its rate limits.
    var isTransient: Bool {
        switch self {
        case .networkError, .serverError, .rateLimited: return true
        default: return false
        }
    }
}
