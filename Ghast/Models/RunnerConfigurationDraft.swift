import Foundation
import Observation

/// The Configuration tab's edits for the runner it shows: environment variables and job
/// scripts as typed, saved through `RunnerService` after half a second of quiet or at once on
/// commit.
@MainActor
@Observable
final class RunnerConfigurationDraft {
    var editor = EnvironmentVariableEditor(rows: [])
    var preScript = ScriptDraft()
    var postScript = ScriptDraft()
    /// Set by a saved edit: it applies the next time the runner starts.
    var needsRestart = false
    private(set) var runnerID: String?

    @ObservationIgnored private let runnerService: RunnerService
    /// One for the draft's lifetime: a pending save always belongs to the runner it captured.
    @ObservationIgnored private let debouncer: SaveDebouncer

    init(runnerService: RunnerService, sleeper: @escaping Sleeper) {
        self.runnerService = runnerService
        debouncer = SaveDebouncer(sleeper: sleeper)
    }

    /// Shows `runner`'s saved configuration, first saving any edit still pending for the
    /// runner shown before.
    func load(_ runner: LocalRunner) {
        debouncer.flush()
        runnerID = runner.id
        editor = EnvironmentVariableEditor(variables: runner.environmentVariables)
        preScript = ScriptDraft(runner.preJobScript)
        postScript = ScriptDraft(runner.postJobScript)
        needsRestart = false
    }

    /// Saves the current edits once typing has been quiet for the debounce delay.
    func saveSoon() {
        guard let id = runnerID else { return }
        let variables = editor.savedVariables
        let pre = preScript.savedScript
        let post = postScript.savedScript
        debouncer.schedule { [weak self, runnerService] in
            guard let current = runnerService.localRunners.first(where: { $0.id == id }) else { return }
            var changed = false
            if current.environmentVariables != variables {
                runnerService.updateRunnerEnvironmentVariables(id: id, environmentVariables: variables)
                changed = true
            }
            if current.preJobScript != pre {
                runnerService.updateRunnerPreJobScript(id: id, script: pre)
                changed = true
            }
            if current.postJobScript != post {
                runnerService.updateRunnerPostJobScript(id: id, script: post)
                changed = true
            }
            if changed, self?.runnerID == id { self?.needsRestart = true }
        }
    }

    /// Saves any pending edit now (field commit, leaving the tab).
    func flush() {
        debouncer.flush()
    }
}
