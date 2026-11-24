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
    /// Which Mac wins the job queue when two Macs run this runner. Applies at once: the
    /// backend reads it live.
    var queueRole = QueueRole.primary
    /// The VM size settings as typed; blank means the image's value.
    var vmCPU = ""
    var vmMemory = ""
    var vmDisk = ""
    var vmIsolated = false
    /// Whether this runner's jobs use Ghast's local Actions cache. Read at each boot.
    var usesLocalCache = true
    /// Set by a saved edit: it applies the next time the runner starts.
    var needsRestart = false
    private(set) var runnerID: String?

    @ObservationIgnored private let runnerService: RunnerService
    @ObservationIgnored private let hostCapacity: any HostCapacity
    /// One for the draft's lifetime: a pending save always belongs to the runner it captured.
    @ObservationIgnored private let debouncer: SaveDebouncer

    init(runnerService: RunnerService, sleeper: @escaping Sleeper, hostCapacity: any HostCapacity = SystemHostCapacity()) {
        self.runnerService = runnerService
        self.hostCapacity = hostCapacity
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
            queueRole = runner.queueRole
            vmCPU = runner.vmResources.cpuCount.map(String.init) ?? ""
            vmMemory = runner.vmResources.memoryGB.map(String.init) ?? ""
            vmDisk = runner.vmResources.diskGB.map(String.init) ?? ""
            vmIsolated = runner.vmResources.isNetworkIsolated
            usesLocalCache = runner.usesLocalCache
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

    // MARK: - VM resources

    enum ResourceField: CaseIterable, Sendable { case cpu, memory, disk }

    enum ResourceInput: Equatable, Sendable {
        case blank
        case value(Int)
        case invalid
    }

    /// A size typed as whole numbers: blank is the image's value, anything outside `range`
    /// or not a number is invalid.
    static func parseResource(_ text: String, range: ClosedRange<Int>) -> ResourceInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .blank }
        guard let number = Int(trimmed), range.contains(number) else { return .invalid }
        return .value(number)
    }

    private static func range(_ lower: Int, upTo upper: Int) -> ClosedRange<Int> {
        lower ... max(lower, upper)
    }

    private func range(for field: ResourceField) -> ClosedRange<Int> {
        switch field {
        case .cpu: Self.range(1, upTo: hostCapacity.coreCount)
        case .memory: Self.range(VMResources.minMemoryGB, upTo: hostCapacity.physicalMemoryGB)
        case .disk: VMResources.diskRange
        }
    }

    private func text(for field: ResourceField) -> String {
        switch field {
        case .cpu: vmCPU
        case .memory: vmMemory
        case .disk: vmDisk
        }
    }

    private func input(for field: ResourceField) -> ResourceInput {
        Self.parseResource(text(for: field), range: range(for: field))
    }

    /// Why the typed value isn't saved; nil when it is blank or valid.
    func resourceIssue(for field: ResourceField) -> String? {
        guard input(for: field) == .invalid else { return nil }
        let range = range(for: field)
        let unit = switch field {
        case .cpu: "cores"
        case .memory, .disk: "GB"
        }
        return "Enter \(range.lowerBound) to \(range.upperBound) \(unit), or leave blank for the image's value."
    }

    /// The valid typed sizes (blank and invalid read as unset), for the warning.
    private var typedSizes: VMResources {
        func value(_ field: ResourceField) -> Int? {
            if case let .value(number) = input(for: field) { return number }
            return nil
        }
        return VMResources(cpuCount: value(.cpu), memoryGB: value(.memory), diskGB: value(.disk))
    }

    /// Typed sizes two VMs couldn't both have on this Mac.
    var overages: [VMResourcesWarning.Overage] {
        VMResourcesWarning.overages(typedSizes, capacity: hostCapacity)
    }

    /// Blank clears a size, a valid value sets it, an invalid one keeps what was saved.
    private static func resolve(_ typed: [ResourceField: ResourceInput], isolated: Bool, saved: VMResources) -> VMResources {
        func resolved(_ field: ResourceField, _ savedValue: Int?) -> Int? {
            switch typed[field] ?? .blank {
            case .blank: nil
            case let .value(number): number
            case .invalid: savedValue
            }
        }
        return VMResources(
            cpuCount: resolved(.cpu, saved.cpuCount),
            memoryGB: resolved(.memory, saved.memoryGB),
            diskGB: resolved(.disk, saved.diskGB),
            isNetworkIsolated: isolated
        )
    }

    /// Saves the current edits once typing has been quiet for the debounce delay.
    func saveSoon() {
        guard let id = runnerID else { return }
        let variables = editor.savedVariables
        let pre = preScript.savedScript
        let post = postScript.savedScript
        let tart = (image: tartImage.trimmingCharacters(in: .whitespacesAndNewlines), group: tartGroup, labels: Self.parseLabels(tartLabels), role: queueRole)
        let typedResources = Dictionary(uniqueKeysWithValues: ResourceField.allCases.map { ($0, input(for: $0)) })
        let isolated = vmIsolated
        let usesLocalCache = usesLocalCache
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
                let resources = Self.resolve(typedResources, isolated: isolated, saved: current.vmResources)
                if current.vmResources != resources {
                    runnerService.updateVMResources(id: id, resources: resources)
                }
                if current.queueRole != tart.role {
                    runnerService.updateRunner(id: id) { $0.queueRole = tart.role }
                }
                if current.usesLocalCache != usesLocalCache {
                    runnerService.updateRunner(id: id) { $0.usesLocalCache = usesLocalCache }
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
