import Foundation
import Observation
import os

/// The repositories New Runner offers, kept across sheet opens. A load inside `freshness`
/// reuses the list; an older list stays on screen while it refreshes; overlapping loads share
/// one request. The list belongs to one account and is dropped when another signs in.
@MainActor
@Observable
final class RepositoryCatalog {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// How long a fetched list counts as current.
    static let freshness: TimeInterval = 5 * 60

    /// The last list that loaded for `account`; nil until one has.
    private(set) var repositories: [GitHubRepository]?
    private(set) var status: Status = .idle

    @ObservationIgnored private let api: any GitHubAPIServiceProtocol
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "new-runner")

    init(api: any GitHubAPIServiceProtocol, clock: any AppClock) {
        self.api = api
        self.clock = clock
    }

    /// Loads the list unless a current one is already here.
    func load(account: String?) async {
        switchAccount(to: account)
        if let fetchedAt, clock.now().timeIntervalSince(fetchedAt) < Self.freshness { return }
        await fetch()
    }

    /// Loads the list now, whatever its age (Retry).
    func retry(account: String?) async {
        switchAccount(to: account)
        await fetch()
    }

    private func switchAccount(to new: String?) {
        guard new != account else { return }
        account = new
        inFlight?.cancel()
        inFlight = nil
        repositories = nil
        fetchedAt = nil
        status = .idle
    }

    /// Joins the request in flight, or starts one.
    private func fetch() async {
        if let inFlight { return await inFlight.value }
        let task = Task { await performFetch(for: account) }
        inFlight = task
        await task.value
    }

    private func performFetch(for requestedAccount: String?) async {
        status = .loading
        let result: Result<[GitHubRepository], Error>
        do {
            result = .success(try await api.fetchRepositories())
        } catch {
            result = .failure(error)
        }
        // Another account signed in meanwhile: this answer isn't theirs.
        guard requestedAccount == account else { return }
        inFlight = nil
        switch result {
        case let .success(list):
            repositories = list
            fetchedAt = clock.now()
            status = .loaded
        case let .failure(error) where error.isCancellation:
            status = repositories == nil ? .idle : .loaded
        case let .failure(error):
            Self.logger.error("Couldn't load repositories: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }
}
