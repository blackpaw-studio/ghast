import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct ScaleSetDemandSourceTests {
    let clock = FakeClock()
    let demand = DemandRecorder()

    private func makeSource(_ replies: [FakeTransport.Reply], groupID: Int = 1) -> (ScaleSetDemandSource, FakeTransport) {
        let transport = FakeTransport([ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600))] + replies)
        let client = ActionsServiceClient(
            scope: .repository(fullName: "octo/ghast"), api: MockGitHubAPIService(),
            transport: transport, clock: clock, sleeper: { _ in }
        )
        let source = ScaleSetDemandSource(
            name: "mac-vm", groupID: { groupID }, client: client, transport: transport, ownerName: "Dionysus"
        )
        return (source, transport)
    }

    private func run(_ source: ScaleSetDemandSource) async {
        _ = try? await source.run(onDemand: demand.record)
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
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(), ScaleSetReplies.noMessage, ScaleSetReplies.noMessage])
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

    @Test("a JIT config comes from the scale set")
    func jit() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.jit(id: 77)])
        let jit = try await source.jitConfig(runnerName: "mac-vm-a1b2c3", workFolder: "_work")
        #expect(jit.runnerID == 77)
        #expect(await transport.requests[2].url?.path == "/abc/_apis/runtime/runnerscalesets/9/generatejitconfig")
    }

    @Test("a run that fails deletes its session before it returns")
    func failedRunClosesSession() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(), .json("", status: 500), ScaleSetReplies.noContent])
        await #expect(throws: ScaleSetError.self) { try await source.run(onDemand: demand.record) }
        #expect(await paths(transport).last == "DELETE /abc/_apis/runtime/runnerscalesets/9/sessions/s-1")
    }

    @Test("close after a cancelled run deletes the session")
    func closeDeletesSession() async throws {
        let (source, transport) = makeSource([ScaleSetReplies.list([9]), ScaleSetReplies.session(), .hang, ScaleSetReplies.noContent])
        let recorder = demand
        let task = Task { try await source.run(onDemand: recorder.record) }
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

/// Collects every demand a source reports.
@MainActor final class DemandRecorder {
    private(set) var values: [Int] = []

    var record: @MainActor (Int) -> Void { { [self] in values.append($0) } }
}
