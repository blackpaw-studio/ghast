import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct ScaleSetDemandSourceTests {
    let clock = FakeClock()
    let demand = DemandRecorder()
    let sleeps = SleepRecorder()

    private func makeSource(_ replies: [FakeTransport.Reply], groupID: Int = 1, timing: QueueTiming = .standard) -> (ScaleSetDemandSource, FakeTransport) {
        let transport = FakeTransport([ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600))] + replies)
        let client = ActionsServiceClient(
            scope: .repository(fullName: "octo/ghast"), api: MockGitHubAPIService(),
            transport: transport, clock: clock, sleeper: { _ in }
        )
        let source = ScaleSetDemandSource(
            name: "mac-vm", groupID: { groupID }, client: client, transport: transport, ownerName: "Dionysus",
            sleeper: sleeps.sleeper, clock: clock, timing: timing
        )
        return (source, transport)
    }

    private func run(_ source: ScaleSetDemandSource) async {
        _ = try? await source.run(demand.context)
    }

    private func paths(_ transport: FakeTransport) async -> [String] {
        await transport.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }
    }

    @Test("an existing scale set with the runner's name is reused")
    func reuse() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 0)], groupID: 3)
        await run(source)
        let requests = await transport.requests
        #expect(requests[1].url?.query?.contains("runnerGroupId=3") == true)
        #expect(requests[1].url?.query?.contains("name=mac-vm") == true)
        #expect(await paths(transport).contains("POST /abc/_apis/runtime/runnerscalesets/9/sessions"))
        #expect(!(await paths(transport)).contains("POST /abc/_apis/runtime/runnerscalesets"))
    }

    @Test("a missing scale set is created in the runner's group")
    func create() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([]), ScaleSetReplies.scaleSet(id: 12), ScaleSetReplies.session()], groupID: 4)
        await run(source)
        let create = await transport.requests[2]
        #expect(create.httpMethod == "POST")
        #expect(create.url?.path == "/abc/_apis/runtime/runnerscalesets")
        let body = try JSONSerialization.jsonObject(with: try #require(create.httpBody)) as? [String: Any]
        #expect(body?["name"] as? String == "mac-vm")
        #expect(body?["runnerGroupId"] as? Int == 4)
        #expect(await paths(transport).contains("POST /abc/_apis/runtime/runnerscalesets/12/sessions"))
    }

    @Test("the session's statistics are the first demand")
    func initialDemand() async throws {
        let (source, _) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 2)])
        await run(source)
        #expect(demand.values == [2])
    }

    @Test("an empty poll reports nothing new and polls again")
    func emptyPoll() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(), ScaleSetReplies.noMessage, ScaleSetReplies.noMessage, .json("", status: 404)])
        await run(source)
        #expect(demand.values == [0])
        #expect(await paths(transport).filter { $0 == "GET /q/abc" }.count == 3)
    }

    @Test("available jobs are acquired, then demand reported, then the message acknowledged")
    func jobAvailable() async throws {
        let body = #"[{"messageType":"JobAvailable","runnerRequestId":11},{"messageType":"JobAvailable","runnerRequestId":12}]"#
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(),
            ScaleSetReplies.message(id: 5, assigned: 2, body: body),
            .json(#"{"count":2,"value":[11,12]}"#),
            .json("", status: 500), // the ack fails: demand must already be out
        ])
        await run(source)
        #expect(demand.values == [0, 2])
        let calls = await paths(transport)
        let acquire = try #require(calls.firstIndex(of: "POST /abc/_apis/runtime/runnerscalesets/9/acquirejobs"))
        let ack = try #require(calls.firstIndex(of: "DELETE /q/abc/5"))
        #expect(acquire < ack)
        let ids = try JSONSerialization.jsonObject(with: try #require(await transport.requests[acquire].httpBody)) as? [Int]
        #expect(ids == [11, 12])
    }

    @Test("a message without available jobs is not acquired and the next poll names it")
    func noAcquireWithoutAvailable() async throws {
        let body = #"[{"messageType":"JobCompleted","runnerRequestId":11,"result":"succeeded"}]"#
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 1),
            ScaleSetReplies.message(id: 7, assigned: 0, body: body), ScaleSetReplies.noContent,
        ])
        await run(source)
        #expect(demand.values == [1, 0])
        let requests = await transport.requests
        #expect(!requests.contains { $0.url!.path.hasSuffix("/acquirejobs") })
        let lastPoll = requests.last { $0.httpMethod == "GET" && $0.url?.host == "queue.example" }
        #expect(lastPoll?.url?.query?.contains("lastMessageId=7") == true)
    }

    @Test("the queue is connecting before the session exists, then held once it does")
    func queueConnectingThenHolding() async throws {
        let (source, _) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 0)])
        await run(source)
        #expect(demand.queue == [.connecting, .holding])
    }

    @Test("a JIT config comes from the scale set")
    func jit() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.jit(id: 77)])
        let jit = try await source.jitConfig(runnerName: "mac-vm-a1b2c3", workFolder: "_work")
        #expect(jit.runnerID == 77)
        #expect(await transport.requests[2].url?.path == "/abc/_apis/runtime/runnerscalesets/9/generatejitconfig")
    }

    @Test("a run that fails deletes its session before it returns")
    func failedRunClosesSession() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(), .json("", status: 404), ScaleSetReplies.noContent])
        await #expect(throws: ScaleSetError.self) { try await source.run(demand.context) }
        #expect(await paths(transport).last == "DELETE /abc/_apis/runtime/runnerscalesets/9/sessions/s-1")
    }

    @Test("a failed poll is retried on the same session, waiting out its backoff or Retry-After")
    func pollRetriesInPlace() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 0),
            .json("", status: 502),
            .json("", status: 429, headers: ["Retry-After": "7"]),
            ScaleSetReplies.message(id: 1, assigned: 3), ScaleSetReplies.noContent,
            .hang,
        ])
        let recorder = demand
        let task = Task { try await source.run(recorder.context) }
        for _ in 0..<10_000 where !demand.values.contains(3) { await Task.yield() }
        task.cancel()
        _ = await task.result

        #expect(demand.values.contains(3))
        #expect(await paths(transport).filter { $0 == "POST /abc/_apis/runtime/runnerscalesets/9/sessions" }.count == 1)
        #expect(sleeps.durations == [.seconds(1), .seconds(7)])
    }

    @Test("polls that keep failing give up after the retry limit and close the session")
    func pollGivesUp() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session()] + Array(repeating: .json("", status: 502), count: 5) + [ScaleSetReplies.noContent])
        await #expect(throws: ScaleSetError.transient("HTTP 502")) { try await source.run(demand.context) }
        #expect(sleeps.durations.count == 4)
        #expect(await paths(transport).last == "DELETE /abc/_apis/runtime/runnerscalesets/9/sessions/s-1")
    }

    @Test("a message of an unknown type is acknowledged and skipped, and the next one handled")
    func unknownMessageTypeSkipped() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 0),
            .json(#"{"messageId":5,"messageType":"SomethingNew","body":"SECRET-BODY","statistics":{"totalAssignedJobs":9}}"#),
            ScaleSetReplies.noContent,
            ScaleSetReplies.message(id: 6, assigned: 2), ScaleSetReplies.noContent,
            .hang,
        ])
        let recorder = demand
        let task = Task { try await source.run(recorder.context) }
        for _ in 0..<10_000 where !demand.values.contains(2) { await Task.yield() }
        task.cancel()
        _ = await task.result

        #expect(demand.values == [0, 2])
        let calls = await paths(transport)
        #expect(calls.contains("DELETE /q/abc/5"))
        #expect(calls.filter { $0 == "POST /abc/_apis/runtime/runnerscalesets/9/sessions" }.count == 1)
    }

    // MARK: Recovery of jobs the queue never announced (issue #39)

    private static let acquirablePath = "GET /abc/_apis/runtime/runnerscalesets/9/acquirablejobs"
    private static let acquirePath = "POST /abc/_apis/runtime/runnerscalesets/9/acquirejobs"

    /// Runs until the transport has seen `requests` requests (the last one is the hanging poll).
    private func run(_ source: ScaleSetDemandSource, _ transport: FakeTransport, until requests: Int, context: DemandRunContext? = nil) async {
        let context = context ?? demand.context
        let task = Task { try await source.run(context) }
        for _ in 0..<10_000 where await transport.requests.count < requests { await Task.yield() }
        task.cancel()
        _ = await task.result
    }

    private func acquiredIDs(_ transport: FakeTransport) async throws -> [[Int]] {
        let bodies = await transport.requests
            .filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/acquirejobs") }
            .compactMap(\.httpBody)
        return try bodies.map { try JSONDecoder().decode([Int].self, from: $0) }
    }

    @Test("a session that starts with available jobs acquires them without a JobAvailable message")
    func sessionStartRecovers() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 0, available: 1),
            ScaleSetReplies.acquirable([31]), ScaleSetReplies.acquired([31]), .hang,
        ])
        await run(source, transport, until: 6)
        let calls = await paths(transport)
        #expect(calls.contains(Self.acquirablePath))
        #expect(try await acquiredIDs(transport) == [[31]])
        #expect(demand.logs == ["Picked up 1 queued job that wasn't announced"])
        // The listing is an admin call, not a queue call.
        let listing = try #require(await transport.requests.first { $0.url!.path.hasSuffix("/acquirablejobs") })
        #expect(listing.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ey") == true)
    }

    @Test("a session that starts with nothing available lists nothing")
    func sessionStartWithoutAvailableJobs() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(), .hang])
        await run(source, transport, until: 4)
        #expect(!(await paths(transport)).contains(Self.acquirablePath))
    }

    @Test("a job missed while holding is acquired at the next reconcile, and polls in between stay quiet")
    func reconcileRecovers() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(),
            ScaleSetReplies.noMessage, ScaleSetReplies.noMessage,
            ScaleSetReplies.acquirable([41]), ScaleSetReplies.acquired([41]), .hang,
        ])
        var context = demand.context
        var reads = 0
        let clock = clock
        // The third loop turn comes a reconcile interval after the session was created.
        context.idleSince = { reads += 1; if reads == 3 { clock.advance(by: 120) }; return nil }
        await run(source, transport, until: 8, context: context)

        let calls = await paths(transport)
        #expect(calls.filter { $0 == Self.acquirablePath }.count == 1)
        let listing = try #require(calls.firstIndex(of: Self.acquirablePath))
        #expect(calls[(listing - 2)..<listing] == ["GET /q/abc", "GET /q/abc"])
        #expect(try await acquiredIDs(transport) == [[41]])
        #expect(demand.logs == ["Picked up 1 queued job that wasn't announced"])
    }

    @Test("statistics that show available jobs the message did not announce trigger a listing")
    func statisticsTriggerRecovery() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(),
            ScaleSetReplies.message(id: 3, assigned: 0, available: 1),
            ScaleSetReplies.acquirable([51]), ScaleSetReplies.acquired([51]), ScaleSetReplies.noContent, .hang,
        ])
        await run(source, transport, until: 8)
        #expect(try await acquiredIDs(transport) == [[51]])
        // Statistics can run ahead of a matrix's messages, so "wasn't announced" is not claimed here.
        #expect(demand.logs.isEmpty)
        let calls = await paths(transport)
        // Recovery runs before the message is acknowledged.
        let acquire = try #require(calls.firstIndex(of: Self.acquirePath))
        let ack = try #require(calls.firstIndex(of: "DELETE /q/abc/3"))
        #expect(acquire < ack)
    }

    @Test("jobs the message announced are not listed again")
    func announcedJobsAreNotListed() async throws {
        let body = #"[{"messageType":"JobAvailable","runnerRequestId":11}]"#
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(),
            ScaleSetReplies.message(id: 3, assigned: 0, available: 1, body: body),
            ScaleSetReplies.acquired([11]), ScaleSetReplies.noContent, .hang,
        ])
        await run(source, transport, until: 7)
        #expect(!(await paths(transport)).contains(Self.acquirablePath))
        #expect(demand.logs.isEmpty)
    }

    @Test("recovery acquires no more than the capacity left")
    func recoveryRespectsCapacity() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 1, available: 3),
            ScaleSetReplies.acquirable([1, 2, 3]), ScaleSetReplies.acquired([1]), .hang,
        ])
        await run(source, transport, until: 6)
        #expect(try await acquiredIDs(transport) == [[1]])
        #expect(demand.logs == ["Picked up 1 queued job that wasn't announced"])
    }

    @Test("a full set lists nothing")
    func fullSetSkipsRecovery() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 2, available: 4), .hang])
        await run(source, transport, until: 4)
        #expect(!(await paths(transport)).contains(Self.acquirablePath))
    }

    @Test("an empty listing acquires nothing and logs nothing", arguments: [ScaleSetReplies.noContent, ScaleSetReplies.acquirable([])])
    func emptyListing(reply: FakeTransport.Reply) async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(available: 1), reply, .hang])
        await run(source, transport, until: 5)
        #expect(try await acquiredIDs(transport).isEmpty)
        #expect(demand.logs.isEmpty)
    }

    @Test("a failed listing does not end the session")
    func failedListingIsBestEffort() async throws {
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(available: 1), .json("", status: 500), .hang,
        ])
        await run(source, transport, until: 5)
        #expect(await paths(transport).filter { $0 == "POST /abc/_apis/runtime/runnerscalesets/9/sessions" }.count == 1)
        #expect(!(await paths(transport)).contains { $0.hasPrefix("DELETE") })
    }

    @Test("a batch with an undecodable element still acquires its available jobs")
    func undecodableElementStillAcquires() async throws {
        let body = #"[{"messageType":"JobAssigned","runnerRequestId":"oops"},{"messageType":"JobAvailable","runnerRequestId":11}]"#
        let (source, transport) = makeSource([
            ScaleSetReplies.list([9]), ScaleSetReplies.session(),
            ScaleSetReplies.message(id: 3, assigned: 1, body: body),
            ScaleSetReplies.acquired([11]), ScaleSetReplies.noContent, .hang,
        ])
        await run(source, transport, until: 7)
        #expect(try await acquiredIDs(transport) == [[11]])
        #expect(demand.values == [0, 1])
    }

    @Test("close after a cancelled run deletes the session")
    func closeDeletesSession() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(), .hang, ScaleSetReplies.noContent])
        let recorder = demand
        let task = Task { try await source.run(recorder.context) }
        while await transport.requests.count < 4 { await Task.yield() }
        task.cancel()
        _ = await task.result
        await source.close()
        #expect(await paths(transport).last == "DELETE /abc/_apis/runtime/runnerscalesets/9/sessions/s-1")
    }

    @Test("deleteRemote deletes the scale set; already gone is fine", arguments: [204, 404])
    func deleteRemote(status: Int) async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), .json("", status: status)])
        try await source.deleteRemote()
        #expect(await paths(transport).last == "DELETE /abc/_apis/runtime/runnerscalesets/9")
    }

    @Test("deleteRemote with no scale set on GitHub sends no delete")
    func deleteRemoteMissing() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([])])
        try await source.deleteRemote()
        #expect(!(await paths(transport)).contains { $0.hasPrefix("DELETE") })
    }
}

/// Collects every demand and queue status a source reports, and answers its role and idle
/// questions from settable values.
@MainActor final class DemandRecorder {
    private(set) var values: [Int] = []
    private(set) var queue: [JobQueueStatus] = []
    private(set) var logs: [String] = []
    var role = QueueRole.primary
    var idleSince: Date?

    var record: @MainActor (Int) -> Void { { [self] in values.append($0) } }

    var context: DemandRunContext {
        DemandRunContext(
            onDemand: { [self] in values.append($0) },
            onQueue: { [self] in queue.append($0) },
            onLog: { [self] in logs.append($0) },
            role: { [self] in role },
            idleSince: { [self] in idleSince }
        )
    }
}
