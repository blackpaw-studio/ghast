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
}
