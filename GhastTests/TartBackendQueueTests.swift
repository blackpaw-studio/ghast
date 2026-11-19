import Testing
import Foundation
@testable import Ghast

@Suite("TartBackend job queue")
@MainActor
struct TartBackendQueueTests {
    /// A started runner with no demand, whose source is running.
    private func start(_ h: TartHarness, role: QueueRole = .primary) async throws -> (LocalRunner, FakeJobDemandSource) {
        let runner = h.addRunner(queueRole: role)
        try await h.service.startRunner(id: runner.id)
        let source = try #require(h.demand.source(runner))
        #expect(await h.settled { source.isRunning })
        return (runner, source)
    }

    @Test("a runner shows connecting until its source says more, then what the source reports")
    func publishesQueueStatus() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)
        #expect(h.vms(runner)?.queue == .connecting)

        source.emitQueue(.heldElsewhere)
        #expect(h.vms(runner)?.queue == .heldElsewhere)
        source.emitQueue(.holding)
        #expect(h.vms(runner)?.queue == .holding)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("each change of queue status is logged once")
    func logsTransitions() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)

        for status in [JobQueueStatus.heldElsewhere, .heldElsewhere, .holding, .holding, .released(.handoff), .heldElsewhere, .holding] {
            source.emitQueue(status)
        }
        await h.service.stopRunner(id: runner.id)

        let queueLines = h.lines.lines.filter { $0.contains("job queue") }
        #expect(queueLines == [
            "Another Mac has the job queue; standing by",
            "Took the job queue",
            "Handing the job queue back to the primary",
            "Another Mac has the job queue; standing by",
            "Took the job queue",
        ])
    }

    @Test("the source reads the runner's role as it is now, so a change applies without a restart")
    func roleIsLive() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let (runner, source) = try await start(h)
        #expect(source.role == .primary)

        h.service.updateRunner(id: runner.id) { $0.queueRole = .standby }
        #expect(source.role == .standby)
        await h.service.stopRunner(id: runner.id)
    }

    @Test("idle starts at launch, ends with demand or a VM, and restarts when the last VM is gone")
    func idleTracking() async throws {
        let h = TartHarness(initialDemand: nil)
        defer { h.cleanup() }
        let launched = h.clock.now()
        let (runner, source) = try await start(h)
        #expect(source.idleSince == launched)

        source.emit(1)
        #expect(await h.settled { h.cli.jobsStarted == 1 })
        #expect(source.idleSince == nil)

        let later = launched.addingTimeInterval(900)
        h.clock.set(later)
        source.emit(0)
        h.cli.endJob(try #require(h.cli.currentJobVM), code: 0)
        #expect(await h.settled { h.vms(runner)?.running == 0 && h.vms(runner)?.booting == 0 && source.idleSince != nil })
        #expect(source.idleSince == later)
        await h.service.stopRunner(id: runner.id)
    }
}
