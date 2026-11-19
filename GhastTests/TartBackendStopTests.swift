import Testing
import Foundation
@testable import Ghast

/// What Stop and cleanup guarantee when something is slow, cancelled or failing.
@Suite("TartBackend stop and cleanup")
@MainActor
struct TartBackendStopTests {
    private func isStopping(_ state: RunnerProcessState?) -> Bool {
        if case .stopping? = state { return true }
        return false
    }

    // MARK: 4. Cleanup survives the cancellation that Stop uses

    @Test("Stop while the runner is being registered still deletes that registration and the VM")
    func stopDuringRegistrationDeletesTheRegistration() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.api.failsWhenCancelled = true
        let gate = HoldGate()
        h.api.jitGate = gate
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.contains { $0.hasPrefix("jit ") } })
        let stopping = Task { await h.service.stopRunner(id: runner.id) }
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        await stopping.value

        #expect(h.log.all.contains("delete 1001 acme/ghast"))
        #expect(h.log.all.contains("delete \(vm)"))
        #expect(h.leases.all().isEmpty)
        #expect(h.state(runner) == .stopped)
    }

    // MARK: 5. A hung guest agent cannot hang Stop

    @Test("a pkill that never returns does not stop the exec from being terminated after the grace period")
    func hungPkillIsBounded() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.pkillGate = HoldGate()
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let stopping = Task { await h.service.stopRunner(id: runner.id) }
        #expect(await h.settled { h.cli.terminatedProcesses.contains("job \(vm)") })
        h.cli.endJob(vm, code: 143)
        await stopping.value

        #expect(h.log.all.contains("delete \(vm)"))
        #expect(h.state(runner) == .stopped)
    }

    // MARK: 6. A VM that will not stop is killed from the host side

    @Test("when tart stop and delete both fail, the host's tart run process is terminated")
    func failedStopTerminatesTheVMProcess() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.stopError = TartError.commandFailed(command: "stop", status: 1, detail: "busy")
        h.cli.deleteError = TartError.commandFailed(command: "delete", status: 1, detail: "running")
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(h.cli.terminatedProcesses.contains("vm \(vm)"))
        // The lease stays, so launch recovery tries the delete again.
        #expect(h.leases.all()[vm] != nil)
    }

    @Test("a clean stop leaves the VM process to end on its own")
    func cleanStopDoesNotTerminateTheVMProcess() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        await h.service.stopRunner(id: runner.id)

        #expect(!h.cli.terminatedProcesses.contains("vm \(vm)"))
    }

    // MARK: 9. Phases shown around Stop and between VMs

    @Test("Stop while an image is pulling shows stopping at once")
    func stopWhilePullingShowsStopping() async throws {
        let h = TartHarness(entries: [])
        defer { h.cleanup() }
        h.cli.pullGate = HoldGate()
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.state(runner) == .pulling(.indeterminate) })
        h.backend.requestStop(id: runner.id, keepingRunIntent: false)

        #expect(isStopping(h.state(runner)))
        await h.service.stopRunner(id: runner.id)
        #expect(h.state(runner) == .stopped)
    }

    @Test("Stop while the VM boots shows stopping, and later phases never overwrite it")
    func stopWhileBootingShowsStopping() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.failedProbesBeforeReady = .max
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.contains { $0.hasPrefix("probe ") } })
        h.backend.requestStop(id: runner.id, keepingRunIntent: false)

        #expect(isStopping(h.state(runner)))
        for _ in 0..<50 {
            await Task.yield()
            if h.state(runner) == .stopped { break }
            #expect(isStopping(h.state(runner)), "got \(String(describing: h.state(runner)))")
        }
        await h.service.stopRunner(id: runner.id)
    }

    @Test("the next VM does not keep showing the last one's cleaning up while it prepares")
    func nextVMIsNotCleaningUp() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let gate = HoldGate()
        h.cli.listGate = gate
        try await h.nextJob(runner)

        #expect(await h.settled { h.log.all.filter { $0 == "list" }.count >= 3 })
        #expect(h.vms(runner) == OnDemandState(since: h.vms(runner)!.since, booting: 1))
        await gate.open()
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a clone that failed is neither stopped nor deleted, and its lease goes")
    func failedCloneIsNotCleanedUp() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.cloneError = TartError.commandFailed(command: "clone", status: 1, detail: "disk full")
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.filter { $0.hasPrefix("clone ") }.count >= 2 })
        await h.service.stopRunner(id: runner.id)

        #expect(!h.log.all.contains { $0.hasPrefix("stop ghast-") || $0.hasPrefix("delete ghast-") })
        #expect(!h.lines.lines.contains { $0.contains("could not delete") })
        #expect(h.leases.all().isEmpty)
    }

    @Test("Stop during the clone stops and deletes nothing, and leaves no lease")
    func stopDuringClone() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let gate = HoldGate()
        h.cli.cloneGate = gate
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.contains { $0.hasPrefix("clone ") } })
        await h.service.stopRunner(id: runner.id)

        #expect(!h.log.all.contains("stop \(vm)"))
        #expect(!h.log.all.contains("delete \(vm)"))
        #expect(h.leases.all().isEmpty)
        #expect(h.state(runner) == .stopped)
    }
}
