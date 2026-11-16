import Foundation

/// Removes runners: stop, unregister on GitHub, trash the folder, drop from the list.
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

    /// Stop → removal token → `config.sh remove` → trash → drop. Throws only when the folder
    /// can't be trashed, after GitHub was told; the runner then stays listed.
    func remove(_ runner: LocalRunner, gitHubRunnerID: Int?) async throws -> Outcome {
        await runnerService.stopRunner(id: runner.id)
        do {
            let token = try await api.createRemoveToken(for: runner.scope)
            try await registrar.unregister(in: URL(fileURLWithPath: runner.path), token: token.token)
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
}
