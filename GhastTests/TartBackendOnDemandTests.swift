import Testing
import Foundation
@testable import Ghast

/// The on-demand scheduler: VMs follow demand, share the host's 2-VM budget, and go away
/// with their job.
@Suite("TartBackend on demand")
@MainActor
struct TartBackendOnDemandTests {
    private func clones(_ h: TartHarness) -> [String] {
        h.log.all.filter { $0.hasPrefix("clone ") }
    }

    private func onDemand(_ state: RunnerProcessState?) -> OnDemandState? {
        if case let .onDemand(value)? = state { return value }
        return nil
    }

    @Test("with no demand a started runner clones nothing and waits for jobs")
    func noDemandNoVM() async throws {
        let h = TartHarness(initialDemand: 0)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.demand.source(runner)?.isRunning == true })
        for _ in 0..<20 { await Task.yield() }

        #expect(clones(h).isEmpty)
        h.demand.source(runner)?.emitQueue(.holding)
        #expect(RunnerDisplayStatus.make(processState: h.state(runner)!, lastExit: nil, activity: RunnerActivity()) == .onDemand(.waitingForJobs(.thisMac)))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a demand of two boots two VMs, each running one job")
    func twoJobsTwoVMs() async throws {
        let h = TartHarness(initialDemand: 2)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 2 })

        #expect(clones(h).count == 2)
        #expect(onDemand(h.state(runner))?.running == 2)
        #expect(Set(h.api.jitRequests.map(\.name)) == ["vm-1-000001", "vm-1-000002"])
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a demand of three still runs at most two VMs")
    func capPerRunner() async throws {
        let h = TartHarness(initialDemand: 3)
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        for _ in 0..<20 { await Task.yield() }
        #expect(clones(h).count == 2)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("two runners share the 2-VM budget: the second waits for a free slot")
    func sharedBudget() async throws {
        let h = TartHarness(initialDemand: 2)
        defer { h.cleanup() }
        let first = h.addRunner()
        try await h.service.startRunner(id: first.id)
        #expect(await h.settled { h.cli.jobsStarted == 2 })

        h.demand.initialDemand = 1
        let second = h.addRunner()
        try await h.service.startRunner(id: second.id)

        #expect(await h.settled { onDemand(h.state(second))?.isWaitingForSlot == true })
        #expect(clones(h).count == 2)
        #expect(RunnerDisplayStatus.make(processState: h.state(second)!, lastExit: nil, activity: RunnerActivity()) == .onDemand(.waitingForSlot))

        // A job on the first runner ends: its VM goes, and the waiting runner takes the slot.
        h.demand.source(first)?.emit(1)
        h.cli.endJob(h.vmName(first, iteration: 1), code: 0)
        #expect(await h.settled { h.log.all.contains { $0.hasPrefix("clone ") && $0.contains(second.id) } })
        #expect(await h.settled { onDemand(h.state(second))?.running == 1 })

        await h.service.stopRunner(id: first.id)
        await h.service.stopRunner(id: second.id)
    }

    @Test("a macOS VM Ghast did not start leaves one slot")
    func foreignVMLeavesOne() async throws {
        let h = TartHarness(
            entries: [
                TartVMEntry(name: TartHarness.image, source: "OCI", isRunning: false),
                TartVMEntry(name: "my-dev-vm", source: "local", isRunning: true),
            ],
            initialDemand: 2
        )
        defer { h.cleanup() }
        let runner = h.addRunner()

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 && onDemand(h.state(runner))?.isWaitingForSlot == true })
        #expect(clones(h).count == 1)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a finished job deletes its VM, and no VM replaces it without new demand")
    func jobFinishDeletes() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        h.demand.source(runner)?.emit(0) // JobCompleted's statistics
        h.cli.endJob(vm, code: 0)

        #expect(await h.settled { h.log.all.contains("delete \(vm)") })
        #expect(await h.settled { onDemand(h.state(runner))?.booting == 0 && onDemand(h.state(runner))?.running == 0 })
        for _ in 0..<20 { await Task.yield() }
        #expect(clones(h).count == 1)
        #expect(h.leases.all().isEmpty)
        #expect(h.backend.isActive(id: runner.id))

        // New demand boots a fresh VM.
        h.demand.source(runner)?.emit(1)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        await h.service.stopRunner(id: runner.id)
    }

    @Test("Stop mid-boot deletes the clone and its lease and closes the demand source")
    func stopMidBoot() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.failedProbesBeforeReady = .max
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.contains("probe \(vm)") })
        await h.service.stopRunner(id: runner.id)

        #expect(h.log.all.contains("delete \(vm)"))
        #expect(h.leases.all().isEmpty)
        #expect(h.demand.source(runner)?.closeCount == 1)
        #expect(h.state(runner) == .stopped)
        #expect(!h.backend.isActive(id: runner.id))
    }

    @Test("a transient demand failure retries with backoff; a config error stops the runner")
    func demandFailures() async throws {
        let h = TartHarness(initialDemand: 0)
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        let source = try #require(h.demand.source(runner))
        #expect(await h.settled { source.isRunning })

        source.failRun(ScaleSetError.transient("HTTP 502"))
        #expect(await h.settled { source.runCount == 2 && source.isRunning })
        #expect(h.sleeps.all.contains(.seconds(5)))
        #expect(h.backend.isActive(id: runner.id))

        source.failRun(TartBackendError.scaleSetAuthRejected)
        #expect(await h.settled { !h.backend.isActive(id: runner.id) })
        guard case .exited? = h.state(runner) else { Issue.record("expected an error state, got \(String(describing: h.state(runner)))"); return }
        #expect(source.closeCount == 1)
        #expect(h.service.localRunners.first?.shouldBeRunning == false)
    }

    @Test("Booting for a queued job shows while the VM boots")
    func bootingState() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        h.cli.failedProbesBeforeReady = .max
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { onDemand(h.state(runner))?.booting == 1 })
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a VM is offered for a shell from its readiness probe until its cleanup starts")
    func liveVMs() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let probe = HoldGate()
        let stop = HoldGate()
        h.cli.probeGate = probe
        h.cli.stopGate = stop
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)

        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.contains("probe \(vm)") })
        #expect(onDemand(h.state(runner))?.liveVMs == [])

        await probe.open()
        #expect(await h.settled { onDemand(h.state(runner))?.liveVMs == [vm] })

        #expect(await h.settled { h.cli.jobsStarted == 1 })
        h.cli.endJob(vm, code: 0)
        #expect(await h.settled { h.log.all.contains("stop \(vm)") })
        #expect(onDemand(h.state(runner))?.liveVMs == [])

        await stop.open()
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a demand failure while a job runs retries the source and leaves the VM and job alone")
    func demandFailureKeepsJobs() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let source = try #require(h.demand.source(runner))

        source.failRun(DemandSourceError.interrupted(ScaleSetError.notFound))

        #expect(await h.settled { source.runCount == 2 && source.isRunning })
        #expect(h.backend.isActive(id: runner.id))
        #expect(onDemand(h.state(runner))?.running == 1)
        #expect(!h.log.all.contains("stop \(vm)"))
        #expect(!h.log.all.contains { $0.hasPrefix("exec \(vm) pkill") })
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a rate-limited demand source waits at least the server's Retry-After")
    func demandRetryAfter() async throws {
        let h = TartHarness(initialDemand: 0)
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        let source = try #require(h.demand.source(runner))
        #expect(await h.settled { source.isRunning })

        source.failRun(DemandSourceError.interrupted(ScaleSetError.rateLimited(retryAfter: 42)))

        #expect(await h.settled { source.runCount == 2 })
        #expect(h.sleeps.all.contains(.seconds(42)))
        #expect(!h.sleeps.all.contains(.seconds(5)))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a VM whose job went away while it booted is deleted before registering, freeing its slot")
    func abandonedBoot() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let probe = HoldGate()
        h.cli.probeGate = probe
        let runner = h.addRunner()
        let vm = h.vmName(runner, iteration: 1)
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.log.all.contains("probe \(vm)") })

        h.demand.source(runner)?.emit(0)
        await probe.open()

        #expect(await h.settled { h.log.all.contains("delete \(vm)") })
        #expect(!h.log.all.contains { $0.hasPrefix("jit ") })
        #expect(await h.settled { onDemand(h.state(runner)) == OnDemandState(since: onDemand(h.state(runner))!.since) })
        #expect(await h.settled { h.leases.all().isEmpty })
        #expect(h.backend.isActive(id: runner.id))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a VM still boots and registers while its job is wanted beyond the VMs already registered")
    func secondJobStillBoots() async throws {
        let h = TartHarness(initialDemand: 2)
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 2 })
        await h.service.stopRunner(id: runner.id)
    }

    @Test("job A's JobCompleted before its VM exits still leaves queued job B a VM")
    func jobCompletedBeforeGuestExit() async throws {
        let h = TartHarness(initialDemand: 1)
        defer { h.cleanup() }
        let runner = h.addRunner()
        let first = h.vmName(runner, iteration: 1)
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let source = try #require(h.demand.source(runner))

        // B queues: VM 2 boots and holds at its probe.
        let probe = HoldGate()
        h.cli.probeGate = probe
        source.emit(2)
        #expect(await h.settled { h.log.all.contains("probe \(h.vmName(runner, iteration: 2))") })
        // A's JobCompleted arrives while A's guest is still exiting.
        source.emit(1)
        await probe.open()
        for _ in 0..<50 { await Task.yield() }
        h.cli.endJob(first, code: 0)

        #expect(await h.settled { h.cli.jobsStarted == 2 })
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a guest that exits before its JobCompleted boots at most one extra VM, which then stands down")
    func guestExitBeforeJobCompleted() async throws {
        let h = TartHarness(initialDemand: 1)
        defer { h.cleanup() }
        let runner = h.addRunner()
        let first = h.vmName(runner, iteration: 1)
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let source = try #require(h.demand.source(runner))

        let probe = HoldGate()
        h.cli.probeGate = probe
        h.cli.endJob(first, code: 0)
        #expect(await h.settled { h.log.all.contains("delete \(first)") })
        for _ in 0..<50 { await Task.yield() }
        source.emit(0)
        await probe.open()

        #expect(await h.settled { onDemand(h.state(runner)) == OnDemandState(since: onDemand(h.state(runner))!.since) && h.leases.all().isEmpty })
        #expect(clones(h).count <= 2)
        #expect(h.api.jitRequests.count == 1)
        #expect(h.cli.jobsStarted == 1)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a source that fails again right after each setup backs off further each time")
    func setupOnlyRunsBackOff() async throws {
        let h = TartHarness(initialDemand: 0)
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        let source = try #require(h.demand.source(runner))

        for run in 1...3 {
            #expect(await h.settled { source.runCount == run && source.isRunning })
            source.failRun(DemandSourceError.interrupted(ScaleSetError.notFound))
        }
        #expect(await h.settled { source.runCount == 4 })
        #expect(h.sleeps.all.filter { $0 >= .seconds(5) } == [.seconds(5), .seconds(10), .seconds(20)])

        // A run that got past setup to a message starts the backoff over.
        #expect(await h.settled { source.isRunning })
        source.emit(0)
        source.failRun(DemandSourceError.interrupted(ScaleSetError.notFound))
        #expect(await h.settled { source.runCount == 5 })
        #expect(h.sleeps.all.filter { $0 >= .seconds(5) }.last == .seconds(5))
        await h.service.stopRunner(id: runner.id)
    }
}
