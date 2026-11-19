import Testing
import Foundation
@testable import Ghast

/// Settable role and idle time for a running source; reading the idle time can move the clock,
/// which stands in for the time a long poll takes.
@MainActor private final class QueueScript {
    var role = QueueRole.primary
    var idleSince: Date?
    private(set) var idleReads = 0
    private let clock: FakeClock
    private let advances: [Int: TimeInterval]

    /// - Parameter advances: Moves the clock by the value at the n-th (1-based) idle read.
    init(clock: FakeClock, advances: [Int: TimeInterval] = [:]) {
        self.clock = clock
        self.advances = advances
    }

    func read() -> Date? {
        idleReads += 1
        if let by = advances[idleReads] { clock.advance(by: by) }
        return idleSince
    }
}

@MainActor @Suite struct ScaleSetQueueTests {
    let clock = FakeClock()
    let demand = DemandRecorder()
    let sleeps = SleepRecorder()

    private static let conflict = FakeTransport.Reply.json("", status: 409)
    private static let sessionPath = "/abc/_apis/runtime/runnerscalesets/9/sessions"

    private func makeSource(_ replies: [FakeTransport.Reply]) -> (ScaleSetDemandSource, FakeTransport) {
        let transport = FakeTransport([ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600)), ScaleSetReplies.list([9])] + replies)
        let client = ActionsServiceClient(
            scope: .repository(fullName: "octo/ghast"), api: MockGitHubAPIService(),
            transport: transport, clock: clock, sleeper: { _ in }
        )
        let source = ScaleSetDemandSource(
            name: "mac-vm", groupID: { 1 }, client: client, transport: transport, ownerName: "Dionysus",
            sleeper: sleeps.sleeper, clock: clock, timing: QueueTiming()
        )
        return (source, transport)
    }

    private func context(_ script: QueueScript) -> DemandRunContext {
        var context = demand.context
        context.role = { script.role }
        context.idleSince = { script.read() }
        return context
    }

    /// Runs the source until the transport has seen `requests` requests (including the one it
    /// hangs on), then cancels it.
    private func run(_ source: ScaleSetDemandSource, _ transport: FakeTransport, script: QueueScript, until requests: Int) async {
        let context = context(script)
        let task = Task { try await source.run(context) }
        for _ in 0..<10_000 where await transport.requests.count < requests { await Task.yield() }
        task.cancel()
        _ = await task.result
    }

    private func calls(_ transport: FakeTransport) async -> [String] {
        await transport.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }
    }

    // MARK: Conflict cadence

    @Test("a primary retries a taken queue every 10 s, with no growing backoff")
    func primaryCadence() async throws {
        let (source, transport) = makeSource([Self.conflict, Self.conflict, Self.conflict, ScaleSetReplies.session(), .hang])
        await run(source, transport, script: QueueScript(clock: clock), until: 7)

        #expect(sleeps.durations == [.seconds(10), .seconds(10), .seconds(10)])
        #expect(demand.queue == [.connecting, .heldElsewhere, .holding])
    }

    @Test("a standby backs off from 5 s to a 60 s cap")
    func standbyCadence() async throws {
        let (source, transport) = makeSource(Array(repeating: Self.conflict, count: 6) + [ScaleSetReplies.session(), .hang])
        let script = QueueScript(clock: clock)
        script.role = .standby
        await run(source, transport, script: script, until: 10)

        #expect(sleeps.durations == [5, 10, 20, 40, 60, 60].map { Duration.seconds($0) })
        #expect(demand.queue == [.connecting, .heldElsewhere, .holding])
    }

    @Test("a conflict ends the wait when the queue frees up, and demand flows from the new session")
    func takesQueueAfterConflict() async throws {
        let (source, transport) = makeSource([Self.conflict, ScaleSetReplies.session(assigned: 2), .hang])
        await run(source, transport, script: QueueScript(clock: clock), until: 5)
        #expect(demand.values == [2])
    }

    // MARK: Standby yield

    @Test("a standby that is not idle keeps the queue, however long it holds it")
    func noYieldWhenBusy() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.session(), ScaleSetReplies.noMessage, ScaleSetReplies.noMessage, .hang])
        let script = QueueScript(clock: clock, advances: [1: 3600])
        script.role = .standby
        await run(source, transport, script: script, until: 6)

        #expect(!(await calls(transport)).contains { $0.hasPrefix("DELETE") })
        #expect(sleeps.durations.isEmpty)
    }

    @Test("a standby keeps the queue until it has been idle for 5 min")
    func noYieldBeforeInterval() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.session(), ScaleSetReplies.noMessage, ScaleSetReplies.noMessage, .hang])
        let script = QueueScript(clock: clock, advances: [1: 299])
        script.role = .standby
        script.idleSince = clock.now()
        await run(source, transport, script: script, until: 6)

        #expect(!(await calls(transport)).contains { $0.hasPrefix("DELETE") })
    }

    @Test("a primary never yields, however long it has been idle")
    func primaryNeverYields() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.session(), ScaleSetReplies.noMessage, ScaleSetReplies.noMessage, .hang])
        let script = QueueScript(clock: clock, advances: [1: 3600])
        script.idleSince = clock.now()
        await run(source, transport, script: script, until: 6)

        #expect(!(await calls(transport)).contains { $0.hasPrefix("DELETE") })
    }

    @Test("an idle standby deletes its session after 5 min, then waits out the 30 s handoff window")
    func yields() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.session(), ScaleSetReplies.noMessage, ScaleSetReplies.noContent, Self.conflict, .hang])
        let script = QueueScript(clock: clock, advances: [2: 300])
        script.role = .standby
        script.idleSince = clock.now()
        await run(source, transport, script: script, until: 7)

        #expect(await calls(transport).dropFirst(2).prefix(5) == [
            "POST \(Self.sessionPath)",
            "GET /q/abc",
            "DELETE \(Self.sessionPath)/s-1",
            "POST \(Self.sessionPath)",
            "POST \(Self.sessionPath)",
        ][...])
        #expect(sleeps.durations.first == .seconds(30))
    }

    @Test("after a handoff a taken queue is reported as held elsewhere, and a free one is taken back without yielding again")
    func handoffOutcomes() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.session(), ScaleSetReplies.noMessage, ScaleSetReplies.noContent,
            Self.conflict, ScaleSetReplies.session(assigned: 1), ScaleSetReplies.noMessage, ScaleSetReplies.noMessage, .hang,
        ])
        let script = QueueScript(clock: clock, advances: [2: 300])
        script.role = .standby
        script.idleSince = clock.now()
        await run(source, transport, script: script, until: 10)

        #expect(demand.queue == [.connecting, .holding, .released(.handoff), .heldElsewhere, .holding])
        #expect(sleeps.durations == [.seconds(30), .seconds(5)])
        #expect(await calls(transport).filter { $0.hasPrefix("DELETE") }.count == 1)
    }
}
