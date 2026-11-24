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

    @Test func vmLocalCacheSwitchLoadsAndSavesWithoutAskingForARestart() {
        var vm = LocalRunner(name: "vm", repository: "o/vm", path: "/tmp/vm")
        vm.backend = .tart(image: "my-vm")
        let service = makeTestRunnerService(runners: [vm])
        let draft = RunnerConfigurationDraft(runnerService: service, sleeper: ManualSleeper().sleeper)
        draft.load(vm)
        #expect(draft.usesLocalCache)

        draft.usesLocalCache = false
        draft.saveSoon()
        draft.flush()

        let saved = service.localRunners.first
        #expect(saved?.usesLocalCache == false)
        #expect(!draft.needsRestart)
        draft.load(saved!)
        #expect(!draft.usesLocalCache)
    }

    @Test func localCacheSwitchNeverChangesAHostRunner() {
        let host = LocalRunner(name: "host", repository: "o/host", path: "/tmp/host")
        let service = makeTestRunnerService(runners: [host])
        let draft = RunnerConfigurationDraft(runnerService: service, sleeper: ManualSleeper().sleeper)
        draft.load(host)

        draft.usesLocalCache = false
        draft.saveSoon()
        draft.flush()

        #expect(service.localRunners.first?.usesLocalCache == true)
        #expect(!draft.needsRestart)
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

    // MARK: - VM resources

    private func makeVMDraft(
        resources: VMResources = .empty,
        capacity: FakeHostCapacity = FakeHostCapacity(coreCount: 16, physicalMemoryGB: 64, freeDisk: 300)
    ) -> (RunnerConfigurationDraft, RunnerService) {
        var vm = LocalRunner(name: "vm", repository: "o/vm", path: "/tmp/vm")
        vm.backend = .tart(image: "my-vm")
        vm.vmResources = resources
        let service = makeTestRunnerService(runners: [vm])
        let draft = RunnerConfigurationDraft(runnerService: service, sleeper: ManualSleeper().sleeper, hostCapacity: capacity)
        draft.load(vm)
        return (draft, service)
    }

    @Test func vmResourcesLoadAndSaveWithoutAskingForARestart() {
        let (draft, service) = makeVMDraft(resources: VMResources(cpuCount: 4, memoryGB: 8, diskGB: 100, isNetworkIsolated: false))
        #expect(draft.vmCPU == "4")
        #expect(draft.vmMemory == "8")
        #expect(draft.vmDisk == "100")
        #expect(!draft.vmIsolated)

        draft.vmCPU = "8"
        draft.vmMemory = "16"
        draft.vmDisk = "150"
        draft.vmIsolated = true
        draft.saveSoon()
        draft.flush()

        #expect(service.localRunners.first?.vmResources == VMResources(cpuCount: 8, memoryGB: 16, diskGB: 150, isNetworkIsolated: true))
        #expect(!draft.needsRestart)
    }

    @Test func blankResourceFieldsSaveAsImageDefault() {
        let (draft, service) = makeVMDraft(resources: VMResources(cpuCount: 4, memoryGB: 8, diskGB: 100, isNetworkIsolated: true))

        draft.vmCPU = ""
        draft.vmMemory = "  "
        draft.vmDisk = ""
        draft.saveSoon()
        draft.flush()

        #expect(service.localRunners.first?.vmResources == VMResources(isNetworkIsolated: true))
    }

    @Test func outOfRangeOrNonNumericResourceKeepsTheSavedValue() {
        let (draft, service) = makeVMDraft(resources: VMResources(cpuCount: 4, memoryGB: 8, diskGB: 100))

        draft.vmCPU = "99"
        draft.vmMemory = "2"
        draft.vmDisk = "abc"
        draft.saveSoon()
        draft.flush()

        #expect(service.localRunners.first?.vmResources == VMResources(cpuCount: 4, memoryGB: 8, diskGB: 100))
        #expect(draft.resourceIssue(for: .cpu) != nil)
        #expect(draft.resourceIssue(for: .memory) != nil)
        #expect(draft.resourceIssue(for: .disk) != nil)
    }

    @Test func validOrBlankResourcesHaveNoIssue() {
        let (draft, _) = makeVMDraft()

        draft.vmCPU = "16"
        draft.vmMemory = ""

        #expect(draft.resourceIssue(for: .cpu) == nil)
        #expect(draft.resourceIssue(for: .memory) == nil)
        #expect(draft.resourceIssue(for: .disk) == nil)
    }

    @Test func typedResourcesDriveTheWarning() {
        let (draft, _) = makeVMDraft()
        #expect(draft.overages.isEmpty)

        draft.vmCPU = "12"

        #expect(draft.overages == [.cpu(limit: 16)])
    }

    @Test func aHostWithFewerCoresThanTheMinimumStillParses() {
        let (draft, _) = makeVMDraft(capacity: FakeHostCapacity(coreCount: 0, physicalMemoryGB: 2, freeDisk: nil))

        draft.vmCPU = "1"
        draft.vmMemory = "4"

        #expect(draft.resourceIssue(for: .cpu) == nil)
        #expect(draft.resourceIssue(for: .memory) == nil)
    }
}
