import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct RunnerConfigurationDraftTests {
    let runnerA = LocalRunner(name: "a", repository: "o/a", path: "/tmp/a")
    let runnerB = LocalRunner(name: "b", repository: "o/b", path: "/tmp/b")

    func makeDraft() -> (RunnerConfigurationDraft, RunnerService, ManualSleeper) {
        let service = makeTestRunnerService(runners: [runnerA, runnerB])
        let sleeper = ManualSleeper()
        return (RunnerConfigurationDraft(runnerService: service, sleeper: sleeper.sleeper), service, sleeper)
    }

    func addVariable(_ draft: RunnerConfigurationDraft) {
        draft.editor.rows.append(EnvironmentVariableDraft(name: "FOO", value: "1"))
        draft.saveSoon()
    }

    @Test func switchingRunnersSavesThePendingEditToTheFirstRunner() {
        let (draft, service, _) = makeDraft()
        draft.load(runnerA)
        addVariable(draft)

        draft.load(runnerB)

        #expect(service.localRunners.first { $0.id == runnerA.id }?.environmentVariables == ["FOO": "1"])
        #expect(service.localRunners.first { $0.id == runnerB.id }?.environmentVariables == [:])
    }

    @Test func editSavesAfterTheQuietDelay() async {
        let (draft, service, sleeper) = makeDraft()
        draft.load(runnerA)
        addVariable(draft)
        #expect(service.localRunners.first { $0.id == runnerA.id }?.environmentVariables == [:])

        while sleeper.requested.isEmpty { await Task.yield() }
        sleeper.wakeAll()
        for _ in 0..<10 { await Task.yield() }

        #expect(service.localRunners.first { $0.id == runnerA.id }?.environmentVariables == ["FOO": "1"])
        #expect(draft.needsRestart)
    }

    @Test func vmSettingsSaveOnFlushWithoutAskingForARestart() {
        var vm = LocalRunner(name: "vm", repository: "o/vm", path: "/tmp/vm", labels: ["self-hosted", "macOS", "ARM64"])
        vm.backend = .tart(image: "ghcr.io/cirruslabs/macos-tahoe-base:latest")
        let service = makeTestRunnerService(runners: [vm])
        let draft = RunnerConfigurationDraft(runnerService: service, sleeper: ManualSleeper().sleeper)
        draft.load(vm)
        #expect(draft.tartLabels == "self-hosted, macOS, ARM64")

        draft.tartImage = "my-vm"
        draft.tartLabels = "self-hosted, xcode"
        draft.tartGroup = "builders"
        draft.saveSoon()
        draft.flush()

        let saved = service.localRunners.first
        #expect(saved?.backend == .tart(image: "my-vm"))
        #expect(saved?.labels == ["self-hosted", "xcode"])
        #expect(saved?.runnerGroup == "builders")
        #expect(!draft.needsRestart)
    }

    @Test func vmQueueRoleLoadsAndSavesWithoutAskingForARestart() {
        var vm = LocalRunner(name: "vm", repository: "o/vm", path: "/tmp/vm")
        vm.backend = .tart(image: "my-vm")
        let service = makeTestRunnerService(runners: [vm])
        let draft = RunnerConfigurationDraft(runnerService: service, sleeper: ManualSleeper().sleeper)
        draft.load(vm)
        #expect(draft.queueRole == .primary)

        draft.queueRole = .standby
        draft.saveSoon()
        draft.flush()

        let saved = service.localRunners.first
        #expect(saved?.queueRole == .standby)
        #expect(!draft.needsRestart)
        draft.load(saved!)
        #expect(draft.queueRole == .standby)
    }

    @Test func blankVMFieldsKeepTheSavedImageAndLabels() {
        var vm = LocalRunner(name: "vm", repository: "o/vm", path: "/tmp/vm", labels: ["self-hosted"])
        vm.backend = .tart(image: "my-vm")
        let service = makeTestRunnerService(runners: [vm])
        let draft = RunnerConfigurationDraft(runnerService: service, sleeper: ManualSleeper().sleeper)
        draft.load(vm)

        draft.tartImage = "  "
        draft.tartLabels = ""
        draft.saveSoon()
        draft.flush()

        #expect(service.localRunners.first?.backend == .tart(image: "my-vm"))
        #expect(service.localRunners.first?.labels == ["self-hosted"])
    }

    @Test func vmScriptsAndVariablesSaveForTheNextVMWithoutARestartOrHostFiles() {
        let folder = makeTemporaryDirectory()
        var vm = LocalRunner(name: "vm", repository: "o/vm", path: folder.path)
        vm.backend = .tart(image: "my-vm")
        let service = makeTestRunnerService(runners: [vm])
        let draft = RunnerConfigurationDraft(runnerService: service, sleeper: ManualSleeper().sleeper)
        draft.load(vm)

        draft.editor.rows.append(EnvironmentVariableDraft(name: "FOO", value: "1"))
        draft.preScript = ScriptDraft("echo before")
        draft.postScript = ScriptDraft("echo after")
        draft.saveSoon()
        draft.flush()

        let saved = service.localRunners.first
        #expect(saved?.environmentVariables == ["FOO": "1"])
        #expect(saved?.preJobScript == "echo before")
        #expect(saved?.postJobScript == "echo after")
        #expect(!draft.needsRestart)
        // The VM gets them from its own share at boot; nothing lands in the runner folder.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(files.isEmpty)
    }
}
