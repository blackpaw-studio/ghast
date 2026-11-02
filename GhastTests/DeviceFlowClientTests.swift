import Testing
import Foundation
@testable import Ghast

/// Records requests and replays queued results. Actor keeps it Sendable.
actor FakeTransport: HTTPTransport {
    enum Reply {
        case json(String, status: Int = 200)
        case failure(Error)
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case let .json(body, status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        }
    }
}

/// Records requested waits instead of sleeping.
actor RecordingSleeper {
    private(set) var waits: [Duration] = []
    private let failOnCall: Int?

    init(failOnCall: Int? = nil) { self.failOnCall = failOnCall }

    func sleep(_ duration: Duration) throws {
        waits.append(duration)
        if waits.count == failOnCall { throw CancellationError() }
    }

    var seconds: [Int] { waits.map { Int($0.components.seconds) } }
}

func formFields(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Suite struct DeviceFlowClientTests {
    static let codeJSON = """
    {"device_code":"dev123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
    """

    @Test func requestCodePostsClientIdAndScopes() async throws {
        let transport = FakeTransport([.json(Self.codeJSON)])
        let client = DeviceFlowClient(transport: transport, sleeper: { _ in })

        let code = try await client.requestCode(scopes: ["repo", "user:email"])

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let fields = formFields(request)
        #expect(fields["client_id"] == DeviceFlowClient.defaultClientID)
        #expect(fields["scope"] == "repo user:email")
        #expect(code == DeviceCode(
            deviceCode: "dev123",
            userCode: "WDJB-MJHT",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        ))
    }
}

@Suite struct DeviceFlowPollingTests {
    static let pending = FakeTransport.Reply.json(#"{"error":"authorization_pending"}"#)
    static let token = FakeTransport.Reply.json(#"{"access_token":"gho_abc","token_type":"bearer","scope":"repo,user:email"}"#)

    func makeCode(interval: Int = 5, expiresIn: Int = 900) -> DeviceCode {
        DeviceCode(
            deviceCode: "dev123",
            userCode: "WDJB-MJHT",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: expiresIn,
            interval: interval
        )
    }

    func makeClient(_ replies: [FakeTransport.Reply], sleeper: RecordingSleeper = RecordingSleeper()) -> (DeviceFlowClient, FakeTransport, RecordingSleeper) {
        let transport = FakeTransport(replies)
        let client = DeviceFlowClient(transport: transport, sleeper: { try await sleeper.sleep($0) })
        return (client, transport, sleeper)
    }

    @Test func succeedsAfterNPending() async throws {
        let (client, transport, sleeper) = makeClient([Self.pending, Self.pending, Self.token])

        let token = try await client.pollForToken(makeCode())

        #expect(token == "gho_abc")
        #expect(await transport.requests.count == 3)
        #expect(await sleeper.seconds == [5, 5, 5])
    }

    @Test func slowDownAddsFiveSeconds() async throws {
        let slow = FakeTransport.Reply.json(#"{"error":"slow_down"}"#)
        let (client, _, sleeper) = makeClient([slow, slow, Self.token])

        _ = try await client.pollForToken(makeCode())

        #expect(await sleeper.seconds == [5, 10, 15])
    }

    @Test func slowDownUsesServerInterval() async throws {
        let slow = FakeTransport.Reply.json(#"{"error":"slow_down","interval":12}"#)
        let (client, _, sleeper) = makeClient([slow, Self.token])

        _ = try await client.pollForToken(makeCode())

        #expect(await sleeper.seconds == [5, 12])
    }

    @Test func expiredTokenThrowsExpired() async {
        let (client, _, _) = makeClient([.json(#"{"error":"expired_token"}"#)])
        await #expect(throws: DeviceFlowError.expired) { try await client.pollForToken(makeCode()) }
    }

    @Test func elapsedPastExpiresInThrowsExpired() async {
        let (client, transport, sleeper) = makeClient([Self.pending, Self.pending, Self.pending])

        await #expect(throws: DeviceFlowError.expired) {
            try await client.pollForToken(makeCode(interval: 5, expiresIn: 12))
        }

        #expect(await sleeper.seconds == [5, 5, 5])
        #expect(await transport.requests.count == 2)
    }

    @Test func accessDeniedThrowsDenied() async {
        let (client, _, _) = makeClient([.json(#"{"error":"access_denied"}"#)])
        await #expect(throws: DeviceFlowError.denied) { try await client.pollForToken(makeCode()) }
    }

    @Test func deviceFlowDisabledThrowsDisabled() async {
        let (client, _, _) = makeClient([.json(#"{"error":"device_flow_disabled"}"#)])
        await #expect(throws: DeviceFlowError.disabled) { try await client.pollForToken(makeCode()) }
    }

    @Test func transportErrorThrowsNetwork() async {
        let (client, _, _) = makeClient([.failure(URLError(.notConnectedToInternet))])
        await #expect {
            try await client.pollForToken(makeCode())
        } throws: { error in
            if case .network = error as? DeviceFlowError { return true }
            return false
        }
    }

    @Test(arguments: [
        #"{"error":"incorrect_client_credentials"}"#,
        "not json",
        #"{"token_type":"bearer"}"#,
    ])
    func unknownErrorOrMalformedThrowsUnexpected(body: String) async {
        let (client, _, _) = makeClient([.json(body)])
        await #expect {
            try await client.pollForToken(makeCode())
        } throws: { error in
            if case .unexpected = error as? DeviceFlowError { return true }
            return false
        }
    }

    @Test func cancellationStopsPolling() async {
        let sleeper = RecordingSleeper(failOnCall: 2)
        let (client, transport, _) = makeClient([Self.pending, Self.pending, Self.token], sleeper: sleeper)

        await #expect(throws: CancellationError.self) { try await client.pollForToken(makeCode()) }

        #expect(await transport.requests.count == 1)
    }

    @Test func noRequestCarriesClientSecret() async throws {
        let (client, transport, _) = makeClient([.json(DeviceFlowClientTests.codeJSON), Self.pending, Self.token])

        let code = try await client.requestCode(scopes: ["repo"])
        _ = try await client.pollForToken(code)

        let requests = await transport.requests
        for request in requests {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!body.contains("client_secret"))
            #expect(request.url?.query?.contains("client_secret") != true)
        }
        let poll = formFields(try #require(requests.last))
        #expect(requests.last?.url?.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(poll["client_id"] == DeviceFlowClient.defaultClientID)
        #expect(poll["device_code"] == "dev123")
        #expect(poll["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
    }
}
