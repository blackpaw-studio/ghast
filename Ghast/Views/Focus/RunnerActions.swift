import AppKit
import os

/// What the sidebar, toolbar and menus can do to a runner. One place, so every entry point
/// behaves the same.
@MainActor
struct RunnerActions {
    let runnerService: RunnerService
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

    /// Starts every runner on this Mac that isn't running.
    func startAll() {
        for runner in runnerService.localRunners where !isRunning(runner.id) { start(runner.id) }
    }

    /// A user stop of every running runner (unlike quitting, it clears their run intent).
    func stopAll() {
        for runner in runnerService.localRunners where isRunning(runner.id) { stop(runner.id) }
    }

    var canStartAll: Bool { runnerService.localRunners.contains { !isRunning($0.id) } }
    var canStopAll: Bool { runnerService.localRunners.contains { isRunning($0.id) } }

    func isRunning(_ localID: String) -> Bool {
        if case .running? = runnerService.processStates[localID] { return true }
        return false
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
}
