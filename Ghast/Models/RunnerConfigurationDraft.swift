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
    /// A VM runner's editable settings, as typed. Labels are comma separated; a blank group
    /// means the default group.
    var tartImage = ""
    var tartGroup = ""
    var tartLabels = ""
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
        if case let .tart(image) = runner.backend {
            tartImage = image
            tartGroup = runner.runnerGroup ?? ""
            tartLabels = runner.labels.joined(separator: ", ")
        }
        needsRestart = false
    }

    /// Labels typed as a comma separated list: trimmed, blanks dropped, duplicates (ignoring
    /// case) kept once. Nil when nothing usable was typed, so a half-edited field never wipes
    /// the saved labels.
    static func parseLabels(_ text: String) -> [String]? {
        var seen = Set<String>()
        let labels = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return labels.isEmpty ? nil : labels
    }

    /// Saves the current edits once typing has been quiet for the debounce delay.
    func saveSoon() {
        guard let id = runnerID else { return }
        let variables = editor.savedVariables
        let pre = preScript.savedScript
        let post = postScript.savedScript
        let tart = (image: tartImage.trimmingCharacters(in: .whitespacesAndNewlines), group: tartGroup, labels: Self.parseLabels(tartLabels))
        debouncer.schedule { [weak self, runnerService] in
            guard let current = runnerService.localRunners.first(where: { $0.id == id }) else { return }
            if case let .tart(savedImage) = current.backend {
                // A VM runner's settings apply to the next VM, so saving them never asks for
                // a restart. A blank image keeps the saved one. Scripts and variables reach
                // the VM through its share at boot, never through the runner folder.
                let image = tart.image.isEmpty ? savedImage : tart.image
                let labels = tart.labels ?? current.labels
                let group = tart.group.trimmingCharacters(in: .whitespacesAndNewlines)
                if image != savedImage || labels != current.labels || (group.isEmpty ? nil : group) != current.runnerGroup {
                    runnerService.updateTartSettings(id: id, labels: labels, runnerGroup: group, image: image)
                }
                if current.environmentVariables != variables || current.preJobScript != pre || current.postJobScript != post {
                    runnerService.updateRunner(id: id) {
                        $0.environmentVariables = variables
                        $0.preJobScript = pre
                        $0.postJobScript = post
                    }
                }
                return
            }
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
