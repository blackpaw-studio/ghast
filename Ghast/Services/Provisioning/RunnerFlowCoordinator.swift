import Foundation
import Observation

/// A question the main window puts to the user before (or after) a runner flow.
enum RunnerFlowPrompt: Equatable, Identifiable {
    case confirmRemove(LocalRunner, gitHubRunnerID: Int?)
    /// GitHub refused; the runner is stopped and still listed.
    case confirmRemoveLocalOnly(LocalRunner, reason: String)
    case confirmReconfigure(LocalRunner)
    case confirmRemoveFromGitHub(name: String, scope: RunnerScope, gitHubRunnerID: Int)
    case failure(title: String, message: String)

    var id: String {
        switch self {
        case let .confirmRemove(runner, _): "remove-\(runner.id)"
        case let .confirmRemoveLocalOnly(runner, _): "remove-local-\(runner.id)"
        case let .confirmReconfigure(runner): "reconfigure-\(runner.id)"
        case let .confirmRemoveFromGitHub(_, scope, id): "remove-github-\(scope.displayName)-\(id)"
        case let .failure(title, _): "failure-\(title)"
        }
    }
}

/// Runs Remove Runner, Reconfigure and Remove from GitHub for the main window. Nothing happens
/// until the user confirms the prompt: unregistering a runner on GitHub can't be undone.
@MainActor @Observable
final class RunnerFlowCoordinator {
    private(set) var prompt: RunnerFlowPrompt?
    private var busy: Set<String> = []

    @ObservationIgnored private let services: RunnerFlowServices
    @ObservationIgnored private let refreshRemote: @MainActor () async -> Void

    init(services: RunnerFlowServices, refreshRemote: @escaping @MainActor () async -> Void) {
        self.services = services
        self.refreshRemote = refreshRemote
    }

    /// A Remove or Reconfigure is running for this runner.
    func isBusy(_ localID: String) -> Bool { busy.contains(localID) }

    func requestRemove(localID: String, gitHubRunnerID: Int?) {
        guard let runner = runner(localID) else { return }
        prompt = .confirmRemove(runner, gitHubRunnerID: gitHubRunnerID)
    }

    func requestReconfigure(localID: String) {
        guard let runner = runner(localID) else { return }
        // A VM runner has no registration to redo; its settings are edited in place.
        if case .tart = runner.backend { return }
        prompt = .confirmReconfigure(runner)
    }

    func requestRemoveFromGitHub(name: String, scope: RunnerScope, gitHubRunnerID: Int) {
        prompt = .confirmRemoveFromGitHub(name: name, scope: scope, gitHubRunnerID: gitHubRunnerID)
    }

    func dismiss() { prompt = nil }

    /// Runs what `prompt` asked about. Takes the prompt itself, since an alert clears its
    /// binding as its button fires. A follow-up question or error becomes the new prompt.
    func confirm(_ prompt: RunnerFlowPrompt) async {
        if self.prompt == prompt { self.prompt = nil }
        switch prompt {
        case let .confirmRemove(runner, gitHubRunnerID):
            await run(runner, failing: "Couldn't Remove “\(runner.name)”") {
                switch try await self.services.remover.remove(runner, gitHubRunnerID: gitHubRunnerID) {
                case .removed: await self.refreshRemote()
                case let .needsLocalOnlyConfirmation(reason): self.prompt = .confirmRemoveLocalOnly(runner, reason: reason)
                }
            }
        case let .confirmRemoveLocalOnly(runner, _):
            await run(runner, failing: "Couldn't Remove “\(runner.name)”") {
                try await self.services.remover.removeFromThisMacOnly(runner)
                await self.refreshRemote()
            }
        case let .confirmReconfigure(runner):
            await run(runner, failing: "Couldn't Reconfigure “\(runner.name)”") {
                try await RunnerReconfigurer(services: self.services).reconfigure(runner)
            }
        case let .confirmRemoveFromGitHub(name, scope, gitHubRunnerID):
            do {
                try await services.remover.removeFromGitHub(gitHubRunnerID: gitHubRunnerID, scope: scope)
                await refreshRemote()
            } catch {
                self.prompt = .failure(title: "Couldn't Remove “\(name)” from GitHub", message: scope.errorMessage(for: error))
            }
        case .failure:
            break
        }
    }

    private func run(_ runner: LocalRunner, failing title: String, _ work: () async throws -> Void) async {
        busy.insert(runner.id)
        defer { busy.remove(runner.id) }
        do {
            try await work()
        } catch {
            prompt = .failure(title: title, message: runner.scope.errorMessage(for: error))
        }
    }

    private func runner(_ localID: String) -> LocalRunner? {
        services.runnerService.localRunners.first { $0.id == localID }
    }
}
