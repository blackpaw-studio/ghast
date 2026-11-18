import Foundation

/// Removes runners: stop, unregister on GitHub, trash the folder, drop from the list.
/// Unregistering can't be undone, so callers confirm first.
@MainActor
struct RunnerRemover {
    let api: any GitHubAPIServiceProtocol
    let runnerService: RunnerService
    let registrar: RunnerRegistrar
    let trasher: any FileTrasher

    enum Outcome: Equatable, Sendable {
        case removed
        /// GitHub couldn't be told. Nothing was trashed; the runner is stopped and still listed.
        case needsLocalOnlyConfirmation(reason: String)
    }

    /// Stop → removal token → `config.sh remove`, falling back to `DELETE` by id → trash →
    /// drop. Throws only when the folder can't be trashed, after GitHub was told; the runner
    /// then stays listed.
    ///
    /// A VM runner registers nothing of its own: stopping its slot deletes the VM and the
    /// one-job registration, so it goes straight to the trash and the list.
    func remove(_ runner: LocalRunner, gitHubRunnerID: Int?) async throws -> Outcome {
        await runnerService.stopRunner(id: runner.id)
        if case .tart = runner.backend {
            try await removeFromThisMacOnly(runner)
            return .removed
        }
        do {
            try await unregister(runner, gitHubRunnerID: gitHubRunnerID)
        } catch {
            return .needsLocalOnlyConfirmation(reason: runner.scope.errorMessage(for: error))
        }
        try await removeFromThisMacOnly(runner)
        return .removed
    }

    /// Trashes the folder (when it still exists) and drops the runner from the list.
    func removeFromThisMacOnly(_ runner: LocalRunner) async throws {
        await runnerService.stopRunner(id: runner.id)
        let folder = URL(fileURLWithPath: runner.path)
        if FileManager.default.fileExists(atPath: folder.path) {
            try await trasher.trash(folder)
        }
        runnerService.removeLocalRunner(id: runner.id)
    }

    /// A runner on another machine: GitHub forgets it; its machine keeps its files.
    func removeFromGitHub(gitHubRunnerID: Int, scope: RunnerScope) async throws {
        try await api.deleteRunner(runnerId: gitHubRunnerID, from: scope)
    }

    // MARK: -

    private func unregister(_ runner: LocalRunner, gitHubRunnerID: Int?) async throws {
        do {
            let token = try await api.createRemoveToken(for: runner.scope)
            try await registrar.unregister(in: URL(fileURLWithPath: runner.path), token: token.token)
        } catch {
            try await deleteByID(runner, knownID: gitHubRunnerID)
        }
    }

    /// The fallback: `DELETE` the runner by id, looking the id up by name when unknown. A
    /// runner GitHub no longer has is already unregistered.
    private func deleteByID(_ runner: LocalRunner, knownID: Int?) async throws {
        let id: Int
        if let knownID {
            id = knownID
        } else {
            let listed = try await api.fetchRunners(in: runner.scope)
            guard let match = listed.first(where: { $0.name.caseInsensitiveCompare(runner.name) == .orderedSame }) else { return }
            id = match.id
        }
        do {
            try await api.deleteRunner(runnerId: id, from: runner.scope)
        } catch GitHubAPIError.notFound {
            return
        }
    }
}
