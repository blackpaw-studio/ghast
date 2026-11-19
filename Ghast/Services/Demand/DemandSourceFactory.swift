import Foundation
import os

/// Builds the demand source for a VM runner.
@MainActor
protocol JobDemandSourceMaking {
    func make(for runner: LocalRunner) -> any JobDemandSource
}

/// A scale set by default. When the scale-set service refuses the token while setting the
/// set up, a repository runner polls the REST API instead; an organization runner stops
/// with `TartBackendError.scaleSetAuthRejected`.
@MainActor
struct DemandSourceFactory: JobDemandSourceMaking {
    let api: any GitHubAPIServiceProtocol
    let transport: any HTTPTransport
    let clock: any AppClock
    let sleeper: Sleeper
    /// The Mac's name, shown as the owner of the scale set's session.
    let ownerName: String
    var retry = ActionsServiceClient.RetryPolicy()
    var queueTiming = QueueTiming.standard

    func make(for runner: LocalRunner) -> any JobDemandSource {
        let client = ActionsServiceClient(scope: runner.scope, api: api, transport: transport, clock: clock, sleeper: sleeper, retry: retry)
        let api = api
        let primary = ScaleSetDemandSource(
            name: runner.name,
            groupID: { try await RunnerGroups.id(for: runner, api: api) },
            client: client,
            transport: transport,
            ownerName: ownerName,
            sleeper: sleeper,
            clock: clock,
            timing: queueTiming,
            retry: retry
        )
        let fallback: (@MainActor () -> any JobDemandSource)?
        switch runner.scope {
        case let .repository(fullName):
            let sleeper = sleeper
            fallback = { RESTPollingDemandSource(repo: fullName, runnerName: runner.name, api: api, sleeper: sleeper) }
        case .organization:
            fallback = nil
        }
        return FallbackDemandSource(primary: primary, fallback: fallback)
    }
}

/// Runs the scale set unless its setup is refused for auth, then the fallback (if any).
@MainActor
final class FallbackDemandSource: JobDemandSource {
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "scaleset")

    private let primary: ScaleSetDemandSource
    private let fallback: (@MainActor () -> any JobDemandSource)?
    private var active: (any JobDemandSource)?

    init(primary: ScaleSetDemandSource, fallback: (@MainActor () -> any JobDemandSource)?) {
        self.primary = primary
        self.fallback = fallback
    }

    /// The source in use once setup has picked one.
    private func resolved() async throws -> any JobDemandSource {
        if let active { return active }
        do {
            _ = try await primary.ensureScaleSet()
            active = primary
            return primary
        } catch ScaleSetError.authRejected {
            guard let fallback else { throw TartBackendError.scaleSetAuthRejected }
            Self.logger.notice("Scale sets refused the token; polling the REST API instead")
            let rest = fallback()
            active = rest
            return rest
        }
    }

    /// Setup failures pass through (a refused org token, a missing group need the user);
    /// once a source is chosen, whatever ends its run is worth another try.
    func run(_ context: DemandRunContext) async throws {
        let source = try await resolved()
        do {
            try await source.run(context)
        } catch {
            if error.isCancellation { throw error }
            throw DemandSourceError.interrupted(error)
        }
    }

    /// Like `run`: past setup, a failed registration fails only that VM, transiently.
    func jitConfig(runnerName: String, workFolder: String) async throws -> GitHubJITConfig {
        let source = try await resolved()
        do {
            return try await source.jitConfig(runnerName: runnerName, workFolder: workFolder)
        } catch {
            if error.isCancellation { throw error }
            throw DemandSourceError.interrupted(error)
        }
    }

    func close() async {
        await active?.close()
    }

    /// Looks the scale set up by name and deletes it; never creates one to do so.
    /// A token scale sets refuse could never have made one, so there is nothing to delete.
    func deleteRemote() async throws {
        do {
            try await primary.deleteRemote()
        } catch ScaleSetError.authRejected {
            Self.logger.notice("Scale sets refused the token; no scale set to delete")
        }
    }
}

/// The runner group a VM runner's registrations go in.
enum RunnerGroups {
    /// Repositories have only the Default group (id 1); an organization resolves the runner's
    /// group by name, falling back to its default group.
    @MainActor
    static func id(for runner: LocalRunner, api: any GitHubAPIServiceProtocol) async throws -> Int {
        guard case let .organization(login) = runner.scope else { return 1 }
        let groups = try await api.fetchRunnerGroups(org: login)
        if let wanted = runner.runnerGroup, !wanted.isEmpty {
            guard let match = groups.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw TartBackendError.runnerGroupNotFound(wanted)
            }
            return match.id
        }
        return groups.first(where: \.isDefault)?.id ?? 1
    }
}
