import AppKit
import os

/// What the sidebar, toolbar and menus can do to a runner. One place, so every entry point
/// behaves the same.
@MainActor
struct RunnerActions {
    let runnerService: RunnerService
    /// Remove and Reconfigure; nil where no flow can run (snapshots).
    var flows: RunnerFlowCoordinator? = nil
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "runner-actions")

    func start(_ localID: String) {
        Task {
            do {
                try await runnerService.startRunner(id: localID)
            } catch {
                Self.logger.error("Couldn't start runner \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop(_ localID: String) {
        Task { await runnerService.stopRunner(id: localID) }
    }

    func restart(_ localID: String) {
        Task {
            await runnerService.stopRunner(id: localID)
            do {
                try await runnerService.startRunner(id: localID)
            } catch {
                Self.logger.error("Couldn't restart runner \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Starts every runner on this Mac that isn't running, leaving any a flow is working on.
    func startAll() {
        for runner in runnerService.localRunners where !isRunning(runner.id) && !isFlowBusy(runner.id) { start(runner.id) }
    }

    /// A user stop of every running runner (unlike quitting, it clears their run intent),
    /// leaving any a flow is working on. Runners still waiting to restart at launch lose their
    /// intent too, so the restart loop leaves them stopped.
    func stopAll() {
        for runner in runnerService.localRunners where (isRunning(runner.id) || runner.shouldBeRunning) && !isFlowBusy(runner.id) {
            stop(runner.id)
        }
    }

    var canStartAll: Bool { runnerService.localRunners.contains { !isRunning($0.id) } }
    var canStopAll: Bool { runnerService.localRunners.contains { isRunning($0.id) } }

    func isRunning(_ localID: String) -> Bool {
        switch runnerService.processStates[localID] {
        case .running?, .onDemand?: return true
        default: return false
        }
    }

    func showInFinder(_ localID: String) {
        guard let runner = runnerService.localRunners.first(where: { $0.id == localID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runner.path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openOnGitHub(_ item: RunnerItem) {
        guard let id = item.gitHubRunnerID, let url = item.scope.runnerSettingsURL(gitHubRunnerID: id) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Flows (each asks first)

    var canRunFlows: Bool { flows != nil }

    func isFlowBusy(_ localID: String) -> Bool { flows?.isBusy(localID) ?? false }

    /// False for a VM runner; unknown IDs count as host runners.
    func isHostRunner(_ localID: String) -> Bool {
        runnerService.localRunners.first { $0.id == localID }?.backend ?? .host == .host
    }

    func reconfigure(_ localID: String) {
        flows?.requestReconfigure(localID: localID)
    }

    /// Without GitHub's id, removal looks the runner up by name.
    func remove(_ localID: String, gitHubRunnerID: Int? = nil) {
        flows?.requestRemove(localID: localID, gitHubRunnerID: gitHubRunnerID)
    }

    func removeFromGitHub(_ item: RunnerItem) {
        guard let id = item.gitHubRunnerID else { return }
        flows?.requestRemoveFromGitHub(name: item.name, scope: item.scope, gitHubRunnerID: id)
    }
}
