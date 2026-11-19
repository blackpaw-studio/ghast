import Testing
import Foundation
@testable import Ghast

@Suite("TartBackend sleep and wake")
@MainActor
struct TartBackendSleepTests {
    private func start(_ h: TartHarness) async throws -> (LocalRunner, FakeJobDemandSource) {
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        let source = try #require(h.demand.source(runner))
        #expect(await h.settled { source.isRunning })
        return (runner, source)
    }

    @Test("sleep stops the demand loop, closes the source's session and says the queue was released")
    func sleepReleasesQueue() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)

        h.power.sleep()

        #expect(await h.settled { !source.isRunning && source.closeCount == 1 })
        #expect(h.vms(runner)?.queue == .released(.sleep))
        #expect(h.lines.lines.contains("Released the job queue (sleep)"))
        await h.service.stopRunner(id: runner.id)
    }

    @Test("sleep leaves running VMs alone")
    func sleepKeepsVMs() async throws {
        let h = TartHarness()
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let vm = try #require(h.cli.currentJobVM)

        h.power.sleep()
        let source = try #require(h.demand.source(runner))
        #expect(await h.settled { source.closeCount == 1 })

        #expect(h.vms(runner)?.running == 1)
        #expect(!h.log.all.contains("stop \(vm)"))
        #expect(!h.log.all.contains("delete \(vm)"))
        h.cli.endJob(vm, code: 0)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("wake runs the source again and shows connecting until it reports")
    func wakeReopens() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)
        h.power.sleep()
        #expect(await h.settled { source.closeCount == 1 && !source.isRunning })

        h.power.wake()

        #expect(await h.settled { source.runCount == 2 && source.isRunning })
        #expect(h.vms(runner)?.queue == .connecting)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("a wake without a sleep does nothing")
    func wakeWithoutSleep() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)

        h.power.wake()
        for _ in 0..<50 { await Task.yield() }
        await h.service.stopRunner(id: runner.id)

        #expect(source.runCount == 1)
        #expect(source.closeCount == 1, "only Stop closes the source")
    }

    @Test("a Stop that lands while a wake is reopening the queue wins")
    func stopDuringWakeSticks() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)
        h.power.sleep()
        #expect(await h.settled { source.closeCount == 1 && !source.isRunning })

        h.power.wake()
        h.backend.requestStop(id: runner.id, keepingRunIntent: false)
        await h.service.stopRunner(id: runner.id)
        for _ in 0..<50 { await Task.yield() }

        #expect(source.runCount == 1)
        #expect(h.state(runner) == .stopped)
    }

    @Test("a runner stopped during sleep stays stopped after wake")
    func stopDuringSleepSticks() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)
        h.power.sleep()
        #expect(await h.settled { source.closeCount == 1 })

        await h.service.stopRunner(id: runner.id)
        h.power.wake()
        for _ in 0..<50 { await Task.yield() }

        #expect(source.runCount == 1)
        #expect(h.state(runner) == .stopped)
    }

    @Test("a VM that finishes during sleep is not replaced")
    func noBootWhileAsleep() async throws {
        let h = TartHarness(initialDemand: 1)
        defer { h.cleanup() }
        let runner = h.addRunner()
        try await h.service.startRunner(id: runner.id)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        let vm = try #require(h.cli.currentJobVM)
        let source = try #require(h.demand.source(runner))

        h.power.sleep()
        #expect(await h.settled { source.closeCount == 1 })
        h.cli.endJob(vm, code: 0)
        #expect(await h.settled { h.log.all.contains("delete \(vm)") && h.vms(runner)?.running == 0 && h.vms(runner)?.booting == 0 })
        for _ in 0..<50 { await Task.yield() }

        #expect(h.log.all.filter { $0.hasPrefix("clone") }.count == 1)
        await h.service.stopRunner(id: runner.id)
    }
}
