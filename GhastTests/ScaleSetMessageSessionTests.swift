import Testing
import Foundation
@testable import Ghast

extension ScaleSetReplies {
    static func session(id: String = "s-1", token: String = "qtok", assigned: Int = 0, available: Int = 0) -> FakeTransport.Reply {
        .json(#"""
        {"sessionId":"\#(id)","ownerName":"Dionysus","messageQueueUrl":"https://queue.example/q/abc?sig=xyz","messageQueueAccessToken":"\#(token)",
         "statistics":{"totalAssignedJobs":\#(assigned),"totalAvailableJobs":\#(available)}}
        """#)
    }

    static func message(id: Int, assigned: Int, available: Int = 0, body: String = "[]") -> FakeTransport.Reply {
        let encoded = String(data: try! JSONEncoder().encode(body), encoding: .utf8)!
        return .json(#"{"messageId":\#(id),"messageType":"RunnerScaleSetJobMessages","body":\#(encoded),"statistics":{"totalAssignedJobs":\#(assigned),"totalAvailableJobs":\#(available)}}"#)
    }

    /// `GET .../acquirablejobs`: the queued jobs nobody has claimed (ARC's `AcquirableJobList`).
    static func acquirable(_ ids: [Int64]) -> FakeTransport.Reply {
        let jobs = ids.map { #"{"runnerRequestId":\#($0),"messageType":"JobRequest","acquireJobUrl":"https://pipelines.example/acquire","requestLabels":["mac-vm"]}"# }
        return .json(#"{"count":\#(ids.count),"value":[\#(jobs.joined(separator: ","))]}"#)
    }

    /// `POST .../acquirejobs`: the ids the service let the set take.
    static func acquired(_ ids: [Int64]) -> FakeTransport.Reply {
        .json(#"{"count":\#(ids.count),"value":\#(ids)}"#)
    }

    static let noMessage = FakeTransport.Reply.json("", status: 202)
}

@MainActor @Suite struct ScaleSetMessageSessionTests {
    let clock = FakeClock()

    private func makeSession(_ replies: [FakeTransport.Reply]) -> (ScaleSetMessageSession, FakeTransport) {
        let transport = FakeTransport([ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600))] + replies)
        let client = ActionsServiceClient(
            scope: .repository(fullName: "octo/ghast"), api: MockGitHubAPIService(),
            transport: transport, clock: clock, sleeper: { _ in }
        )
        return (ScaleSetMessageSession(client: client, scaleSetID: 9, transport: transport), transport)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("create posts the owner name and returns the session's statistics")
    func create() async throws {
        let (session, transport) = makeSession([ScaleSetReplies.session(assigned: 2)])
        let created = try await session.create(ownerName: "Dionysus")
        #expect(created.statistics?.totalAssignedJobs == 2)
        let request = await transport.requests[1]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/abc/_apis/runtime/runnerscalesets/9/sessions")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["ownerName": "Dionysus"])
    }

    @Test("202 means no message")
    func noMessage() async throws {
        let (session, _) = makeSession([ScaleSetReplies.session(), ScaleSetReplies.noMessage])
        _ = try await session.create(ownerName: "Dionysus")
        #expect(try await session.nextMessage(lastID: 0) == nil)
    }

    @Test("the poll asks the queue with its token, capacity 2 and a long timeout; lastMessageId only once positive")
    func pollRequest() async throws {
        let (session, transport) = makeSession([
            ScaleSetReplies.session(), ScaleSetReplies.message(id: 5, assigned: 1), ScaleSetReplies.noMessage,
        ])
        _ = try await session.create(ownerName: "Dionysus")
        let message = try await session.nextMessage(lastID: 0)
        #expect(message?.messageID == 5)
        #expect(message?.statistics?.totalAssignedJobs == 1)
        _ = try await session.nextMessage(lastID: 5)

        let requests = await transport.requests
        let first = requests[2]
        #expect(first.httpMethod == "GET")
        #expect(first.url?.host == "queue.example")
        #expect(query(first) == ["sig": "xyz"])
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer qtok")
        #expect(first.value(forHTTPHeaderField: "Accept") == "application/json; api-version=6.0-preview")
        #expect(first.value(forHTTPHeaderField: "X-ScaleSetMaxCapacity") == "2")
        #expect(first.timeoutInterval >= 120)
        #expect(query(requests[3]) == ["sig": "xyz", "lastMessageId": "5"])
    }

    @Test("ack deletes the message under the queue path, keeping its query")
    func ack() async throws {
        let (session, transport) = makeSession([ScaleSetReplies.session(), ScaleSetReplies.noContent])
        _ = try await session.create(ownerName: "Dionysus")
        try await session.ack(id: 5)
        let request = await transport.requests[2]
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/q/abc/5")
        #expect(query(request) == ["sig": "xyz"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer qtok")
    }

    @Test("a 401 from the queue refreshes the session and retries once with the new token")
    func refreshOn401() async throws {
        let (session, transport) = makeSession([
            ScaleSetReplies.session(token: "old"), .json("", status: 401),
            ScaleSetReplies.session(token: "new"), ScaleSetReplies.noMessage,
        ])
        _ = try await session.create(ownerName: "Dionysus")
        #expect(try await session.nextMessage(lastID: 0) == nil)
        let requests = await transport.requests
        #expect(requests[3].httpMethod == "PATCH")
        #expect(requests[3].url?.path == "/abc/_apis/runtime/runnerscalesets/9/sessions/s-1")
        #expect(requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("a second 401 after the refresh is an error")
    func secondUnauthorized() async throws {
        let (session, _) = makeSession([
            ScaleSetReplies.session(), .json("", status: 401), ScaleSetReplies.session(token: "new"), .json("", status: 401),
        ])
        _ = try await session.create(ownerName: "Dionysus")
        await #expect(throws: ScaleSetError.authRejected) { try await session.nextMessage(lastID: 0) }
    }

    @Test("acquire posts the request ids with the queue token")
    func acquire() async throws {
        let (session, transport) = makeSession([ScaleSetReplies.session(), .json(#"{"count":2,"value":[11,12]}"#)])
        _ = try await session.create(ownerName: "Dionysus")
        #expect(try await session.acquire(requestIDs: [11, 12]) == [11, 12])
        let request = await transport.requests[2]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/abc/_apis/runtime/runnerscalesets/9/acquirejobs")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer qtok")
        let ids = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [Int]
        #expect(ids == [11, 12])
    }

    @Test("acquire refreshes on 401")
    func acquireRefresh() async throws {
        let (session, transport) = makeSession([
            ScaleSetReplies.session(token: "old"), .json("", status: 401), ScaleSetReplies.session(token: "new"),
            .json(#"{"count":1,"value":[11]}"#),
        ])
        _ = try await session.create(ownerName: "Dionysus")
        #expect(try await session.acquire(requestIDs: [11]) == [11])
        #expect(await transport.requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("close deletes the session")
    func close() async throws {
        let (session, transport) = makeSession([ScaleSetReplies.session(), ScaleSetReplies.noContent])
        _ = try await session.create(ownerName: "Dionysus")
        try await session.close()
        let request = await transport.requests[2]
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/abc/_apis/runtime/runnerscalesets/9/sessions/s-1")
    }

    @Test("close without a session sends nothing")
    func closeWithoutSession() async throws {
        let (session, transport) = makeSession([])
        try await session.close()
        #expect(await transport.requests.isEmpty)
    }
}
