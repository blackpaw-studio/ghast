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

    func make(for runner: LocalRunner) -> any JobDemandSource {
        let client = ActionsServiceClient(scope: runner.scope, api: api, transport: transport, clock: clock, sleeper: sleeper, retry: retry)
        let api = api
        let primary = ScaleSetDemandSource(
            name: runner.name,
            groupID: { try await RunnerGroups.id(for: runner, api: api) },
            client: client,
            transport: transport,
            ownerName: ownerName
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

    func run(onDemand: @escaping @MainActor (Int) -> Void) async throws {
        try await resolved().run(onDemand: onDemand)
    }

    func jitConfig(runnerName: String, workFolder: String) async throws -> GitHubJITConfig {
        try await resolved().jitConfig(runnerName: runnerName, workFolder: workFolder)
    }

    func close() async {
        await active?.close()
    }

    /// Looks the scale set up by name and deletes it; never creates one to do so.
    func deleteRemote() async throws {
        try await primary.deleteRemote()
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
