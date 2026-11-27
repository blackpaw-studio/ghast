import Testing
import Foundation
@testable import Ghast

/// What the job history records as a VM goes from claimed to gone, with a fake Tart whose
/// guest stream the tests feed line by line.
@Suite("TartBackend job history")
@MainActor
struct TartBackendJobHistoryTests {
    private let stamp = "2026-11-27T10:00:00-0500"

    private func marker(repository: String = "acme/ghast", runID: String = "9001", attempt: String = "2") -> String {
        let b64 = { (text: String) in Data(text.utf8).base64EncodedString() }
        return "\(stamp) ghast: run-info repository=\(b64(repository)) workflow=\(b64("CI")) run_id=\(b64(runID)) run_attempt=\(b64(attempt))"
    }

    private func startJob(_ h: TartHarness, _ vm: String, name: String = "build", repository: String = "acme/ghast") {
        h.cli.emitGuestLine(vm, "\(stamp) 2026-11-27 15:00:00Z: Running job: \(name)")
        h.cli.emitGuestLine(vm, marker(repository: repository))
    }

    private func complete(_ h: TartHarness, _ vm: String, name: String = "build", result: String) {
        h.cli.emitGuestLine(vm, "\(stamp) 2026-11-27 15:05:00Z: Job \(name) completed with result: \(result)")
    }

    private func records(_ h: TartHarness, _ runner: LocalRunner) -> [JobHistoryRecord] {
        h.history.records(for: runner.id)
    }

    private func vmID(_ iteration: Int) -> String { String(format: "%06x", iteration) }

    @Test("a clone that fails is a Didn't start row with the error the backend logged")
    func cloneFailure() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.cloneError = TartError.commandFailed(command: "clone", status: 1, detail: "disk full")
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { records(h, runner).contains { $0.result == .didNotStart } })
        await h.service.stopRunner(id: runner.id)

        let record = try #require(records(h, runner).last)
        #expect(record.result == .didNotStart)
        #expect(record.id == vmID(1))
        #expect(record.failureMessage == "Error: \(TartError.commandFailed(command: "clone", status: 1, detail: "disk full").localizedDescription)")
        #expect(record.finishedAt != nil)
        #expect(record.runURL == nil)
    }

    @Test("a job that reports a result is recorded with its run and link", arguments: [
        ("Succeeded", JobHistoryResult.succeeded), ("Failed", .failed), ("Canceled", .cancelled),
    ])
    func results(word: String, expected: JobHistoryResult) async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        startJob(h, vm)
        #expect(await h.settled { records(h, runner).first?.runID == 9001 })
        #expect(records(h, runner).first?.result == .running)
        complete(h, vm, result: word)
        h.cli.endJob(vm, code: 0)
        #expect(await h.settled { h.log.all.contains("delete \(vm)") })
        await h.service.stopRunner(id: runner.id)

        let record = try #require(records(h, runner).first)
        #expect(records(h, runner).count == 1)
        #expect(record.result == expected)
        #expect(record.jobName == "build")
        #expect(record.workflowName == "CI")
        #expect(record.repository == "acme/ghast")
        #expect(record.runURL?.absoluteString == "https://github.com/acme/ghast/actions/runs/9001/attempts/2")
        #expect(record.finishedAt != nil)
    }

    @Test("Stop after the job started leaves an Unknown row that keeps its link")
    func stopIsUnknown() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        startJob(h, vm)
        await h.service.stopRunner(id: runner.id)

        let record = try #require(records(h, runner).first)
        #expect(record.result == .unknown)
        #expect(record.jobName == "build")
        #expect(record.runURL != nil)
    }

    @Test("the guest ending without a result is Unknown")
    func endedWithoutResult() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        startJob(h, vm)
        h.cli.endJob(vm, code: 137)
        #expect(await h.settled { records(h, runner).first?.result == .unknown })
        await h.service.stopRunner(id: runner.id)

        #expect(records(h, runner).first?.jobName == "build")
    }

    @Test("a VM that never got a slot leaves no record")
    func noSlot() async throws {
        let h = TartHarness(
            entries: [
                TartVMEntry(name: TartHarness.image, source: "OCI", isRunning: false),
                TartVMEntry(name: "dev-1", source: "local", isRunning: true),
                TartVMEntry(name: "dev-2", source: "local", isRunning: true),
            ]
        )
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.vms(runner)?.isWaitingForSlot == true })
        await h.service.stopRunner(id: runner.id)

        #expect(records(h, runner).isEmpty)
        #expect(h.historyStore.saveCount == 0)
    }

    @Test("a VM whose job went away while it booted leaves no record")
    func abandoned() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let gate = HoldGate()
        h.cli.probeGate = gate
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.contains("run \(vm) ghast:ro,ghast-job:ro") })
        h.demand.source(runner)?.emit(0)
        await gate.open()
        #expect(await h.settled { h.log.all.contains("delete \(vm)") })
        await h.service.stopRunner(id: runner.id)

        #expect(!h.log.all.contains { $0.hasPrefix("exec-stream") })
        #expect(records(h, runner).isEmpty)
    }

    @Test("the runner exiting cleanly before any job leaves no record; a non-zero exit is Didn't start")
    func exitBeforeJob() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        h.demand.source(runner)?.emit(0)
        h.cli.endJob(vm, code: 0)
        #expect(await h.settled { h.log.all.contains("delete \(vm)") })
        #expect(records(h, runner).isEmpty)

        h.demand.source(runner)?.emit(1)
        let second = h.vmName(runner, iteration: 2)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        h.cli.endJob(second, code: 3)
        #expect(await h.settled { records(h, runner).contains { $0.result == .didNotStart } })
        await h.service.stopRunner(id: runner.id)

        let record = try #require(records(h, runner).first { $0.result == .didNotStart })
        #expect(record.failureMessage == "Error: \(TartBackendError.runnerExited(3).localizedDescription)")
    }

    @Test("run info from another owner is dropped: no link, the rest of the record stays")
    func foreignOwner() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner(scope: .organization(login: "acme"))
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        startJob(h, vm, repository: "evil/app")
        complete(h, vm, result: "Succeeded")
        h.cli.endJob(vm, code: 0)
        #expect(await h.settled { records(h, runner).first?.result == .succeeded })
        await h.service.stopRunner(id: runner.id)

        let record = try #require(records(h, runner).first)
        #expect(record.repository == nil)
        #expect(record.runURL == nil)
        #expect(record.workflowName == "CI")
        #expect(record.runID == 9001)
    }

    @Test("two VMs running jobs with the same name each keep their own result")
    func twoVMsSameName() async throws {
        let h = TartHarness(initialDemand: 2)
        defer { h.cleanup() }
        let runner = h.addRunner()
        let first = h.vmName(runner, iteration: 1)
        let second = h.vmName(runner, iteration: 2)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        startJob(h, first)
        startJob(h, second)
        complete(h, second, result: "Failed")
        complete(h, first, result: "Succeeded")
        h.cli.endJob(first, code: 0)
        h.cli.endJob(second, code: 1)
        #expect(await h.settled { records(h, runner).allSatisfy { $0.result != .running } && records(h, runner).count == 2 })
        await h.service.stopRunner(id: runner.id)

        let byID = Dictionary(uniqueKeysWithValues: records(h, runner).map { ($0.id, $0.result) })
        #expect(byID == [vmID(1): .succeeded, vmID(2): .failed])
    }
}
