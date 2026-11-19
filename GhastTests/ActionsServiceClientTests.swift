import Testing
import Foundation
@testable import Ghast

/// A JWT whose payload carries only `exp`; the signature is never checked.
func fakeJWT(exp: Date) -> String {
    func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(#"{"alg":"none"}"#)).\(b64url(#"{"exp":\#(Int(exp.timeIntervalSince1970))}"#)).sig"
}

/// Canned Actions-service replies shared by the scale-set suites.
enum ScaleSetReplies {
    static let serviceURL = "https://pipelines.actions.example/abc/"

    static func connection(exp: Date) -> FakeTransport.Reply {
        .json(#"{"url":"\#(serviceURL)","token":"\#(fakeJWT(exp: exp))"}"#, status: 201)
    }

    static func list(_ ids: [Int], name: String = "mac-vm") -> FakeTransport.Reply {
        let sets = ids.map { #"{"id":\#($0),"name":"\#(name)","runnerGroupId":1,"RunnerSetting":{}}"# }
        return .json(#"{"count":\#(ids.count),"value":[\#(sets.joined(separator: ","))]}"#)
    }

    static func scaleSet(id: Int, name: String = "mac-vm") -> FakeTransport.Reply {
        .json(#"{"id":\#(id),"name":"\#(name)","runnerGroupId":1,"RunnerSetting":{"disableUpdate":true}}"#)
    }

    static func jit(id: Int, config: String = "QUJD") -> FakeTransport.Reply {
        .json(#"{"runner":{"id":\#(id),"name":"mac-vm-a","runnerScaleSetId":9},"encodedJITConfig":"\#(config)"}"#)
    }

    static let noContent = FakeTransport.Reply.json("", status: 204)
}

@MainActor @Suite struct ActionsServiceClientTests {
    let clock = FakeClock()
    let api = MockGitHubAPIService()
    let sleeps = SleepRecorder()

    private func makeClient(_ replies: [FakeTransport.Reply], scope: RunnerScope = .repository(fullName: "octo/ghast")) -> (ActionsServiceClient, FakeTransport) {
        let transport = FakeTransport(replies)
        let client = ActionsServiceClient(scope: scope, api: api, transport: transport, clock: clock, sleeper: sleeps.sleeper)
        return (client, transport)
    }

    private var hourFromNow: Date { clock.now().addingTimeInterval(3600) }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("the handshake gets a registration token, trades it at runner-registration, then calls the service with the JWT")
    func handshake() async throws {
        let exp = hourFromNow
        let (client, transport) = makeClient([ScaleSetReplies.connection(exp: exp), ScaleSetReplies.list([9])])

        let set = try await client.scaleSet(named: "mac-vm", groupID: 3)

        #expect(set?.id == 9)
        #expect(api.registrationTokenScopes == [.repository(fullName: "octo/ghast")])
        let requests = await transport.requests
        #expect(requests.count == 2)
        let registration = requests[0]
        #expect(registration.httpMethod == "POST")
        #expect(registration.url?.absoluteString == "https://api.github.com/actions/runner-registration")
        #expect(registration.value(forHTTPHeaderField: "Authorization") == "RemoteAuth mock-registration-token")
        #expect(registration.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try json(registration)
        #expect(body["url"] as? String == "https://github.com/octo/ghast")
        #expect(body["runner_event"] as? String == "register")

        let get = requests[1]
        #expect(get.httpMethod == "GET")
        #expect(get.url?.path == "/abc/_apis/runtime/runnerscalesets")
        #expect(query(get) == ["runnerGroupId": "3", "name": "mac-vm", "api-version": "6.0-preview"])
        #expect(get.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeJWT(exp: exp))")
        #expect(get.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("an organization registers against the organization URL")
    func organizationURL() async throws {
        let (client, transport) = makeClient([ScaleSetReplies.connection(exp: hourFromNow), ScaleSetReplies.list([])], scope: .organization(login: "octo"))
        #expect(try await client.scaleSet(named: "mac-vm", groupID: 1) == nil)
        let body = try json(await transport.requests[0])
        #expect(body["url"] as? String == "https://github.com/octo")
    }

    @Test("the admin token is reused until 60 s before it expires, then refreshed")
    func tokenRefresh() async throws {
        let (client, transport) = makeClient([
            ScaleSetReplies.connection(exp: hourFromNow), ScaleSetReplies.list([9]),
            ScaleSetReplies.list([9]),
            ScaleSetReplies.connection(exp: hourFromNow.addingTimeInterval(3600)), ScaleSetReplies.list([9]),
        ])
        _ = try await client.scaleSet(named: "mac-vm", groupID: 1)
        clock.advance(by: 3600 - 61)
        _ = try await client.scaleSet(named: "mac-vm", groupID: 1)
        #expect(await transport.requests.count == 3)
        clock.advance(by: 2)
        _ = try await client.scaleSet(named: "mac-vm", groupID: 1)

        let paths = await transport.requests.map { $0.url!.path }
        #expect(paths.filter { $0 == "/actions/runner-registration" }.count == 2)
        #expect(api.registrationTokenScopes.count == 2)
    }

    @Test("concurrent calls share one handshake")
    func oneRefreshInFlight() async throws {
        let (client, transport) = makeClient([
            ScaleSetReplies.connection(exp: hourFromNow), ScaleSetReplies.list([9]), ScaleSetReplies.list([9]),
        ])
        async let first = client.scaleSet(named: "mac-vm", groupID: 1)
        async let second = client.scaleSet(named: "mac-vm", groupID: 1)
        _ = try await (first, second)
        let paths = await transport.requests.map { $0.url!.path }
        #expect(paths.filter { $0 == "/actions/runner-registration" }.count == 1)
    }

    @Test("401 and 403 at runner-registration are retried; past the budget they reject auth")
    func registrationRejected() async throws {
        let (client, transport) = makeClient(Array(repeating: .json(#"{"message":"no"}"#, status: 403), count: 5))
        await #expect(throws: ScaleSetError.authRejected) {
            try await client.scaleSet(named: "mac-vm", groupID: 1)
        }
        #expect(await transport.requests.count == 5)
        #expect(sleeps.durations.count == 4)
        #expect(sleeps.durations == sleeps.durations.sorted())
    }

    @Test("a fresh registration token that fails once is retried and then works")
    func registrationRetrySucceeds() async throws {
        let (client, _) = makeClient([.json("", status: 401), ScaleSetReplies.connection(exp: hourFromNow), ScaleSetReplies.list([9])])
        #expect(try await client.scaleSet(named: "mac-vm", groupID: 1)?.id == 9)
    }

    @Test("a rate-limited 403 at runner-registration is a rate limit, not an auth failure")
    func registrationRateLimited() async throws {
        let (client, transport) = makeClient([.json(#"{"message":"slow down"}"#, status: 403, headers: ["Retry-After": "30"])])
        await #expect(throws: ScaleSetError.rateLimited(retryAfter: 30)) {
            try await client.scaleSet(named: "mac-vm", groupID: 1)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("a 401 creating the scale set rejects auth")
    func createUnauthorized() async throws {
        let (client, _) = makeClient([ScaleSetReplies.connection(exp: hourFromNow), .json("", status: 401)])
        await #expect(throws: ScaleSetError.authRejected) {
            try await client.createScaleSet(name: "mac-vm", groupID: 1)
        }
    }

    @Test("create posts the scale-set body and decodes the reply")
    func create() async throws {
        let (client, transport) = makeClient([ScaleSetReplies.connection(exp: hourFromNow), ScaleSetReplies.scaleSet(id: 12)])
        let set = try await client.createScaleSet(name: "mac-vm", groupID: 4)
        #expect(set.id == 12)
        let request = await transport.requests[1]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/abc/_apis/runtime/runnerscalesets")
        let body = try json(request)
        #expect(body["runnerGroupId"] as? Int == 4)
        #expect(body["RunnerSetting"] != nil)
    }

    @Test("delete removes the set and treats 404 as already gone", arguments: [204, 404])
    func delete(status: Int) async throws {
        let (client, transport) = makeClient([ScaleSetReplies.connection(exp: hourFromNow), .json("", status: status)])
        try await client.deleteScaleSet(id: 9)
        let request = await transport.requests[1]
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/abc/_apis/runtime/runnerscalesets/9")
    }

    @Test("a JIT config posts the name and work folder to the set")
    func jitConfig() async throws {
        let (client, transport) = makeClient([ScaleSetReplies.connection(exp: hourFromNow), ScaleSetReplies.jit(id: 77)])
        let jit = try await client.jitConfig(scaleSetID: 9, name: "mac-vm-a1b2c3", workFolder: "_work")
        #expect(jit == GitHubJITConfig(runnerID: 77, encodedConfig: "QUJD"))
        let request = await transport.requests[1]
        #expect(request.url?.path == "/abc/_apis/runtime/runnerscalesets/9/generatejitconfig")
        let body = try json(request)
        #expect(body["name"] as? String == "mac-vm-a1b2c3")
        #expect(body["workFolder"] as? String == "_work")
    }

    @Test("service failures map to errors", arguments: [
        (500, "", ScaleSetError.transient("HTTP 500")),
        (409, "", .conflict),
        (404, "", .notFound),
        (400, #"{"typeName":"ArgumentException","message":"bad name"}"#, .badRequest("bad name")),
    ])
    func failures(status: Int, body: String, expected: ScaleSetError) async throws {
        let (client, _) = makeClient([ScaleSetReplies.connection(exp: hourFromNow), .json(body, status: status)])
        await #expect(throws: expected) {
            try await client.createScaleSet(name: "mac-vm", groupID: 1)
        }
    }

    @Test("a success status Ghast did not expect never carries its body, which may hold a token")
    func unexpectedSuccessHidesBody() {
        let response = HTTPURLResponse(url: URL(string: "https://x.example")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let error = ActionsServiceClient.error(for: response, body: Data(#"{"token":"SECRET-TOKEN","encoded_jit_config":"SECRET-JIT"}"#.utf8), now: Date())
        #expect(error == .badResponse("HTTP 200"))
    }

    @Test("a failure's body is cut short and kept to one line")
    func failureBodyIsSanitized() throws {
        let response = HTTPURLResponse(url: URL(string: "https://x.example")!, statusCode: 418, httpVersion: nil, headerFields: nil)!
        let body = "first line\nsecond\tline " + String(repeating: "x", count: 1_000)
        guard case let .badResponse(message) = ActionsServiceClient.error(for: response, body: Data(body.utf8), now: Date()) else {
            Issue.record("expected badResponse"); return
        }
        #expect(message.hasPrefix("HTTP 418: first line second line x"))
        #expect(!message.contains("\n") && !message.contains("\t"))
        #expect(message.count <= "HTTP 418: ".count + ActionsServiceClient.maxErrorDetailLength + 1)
    }

    @Test("a network failure is transient")
    func networkFailure() async throws {
        let (client, _) = makeClient([ScaleSetReplies.connection(exp: hourFromNow), .failure(URLError(.timedOut))])
        await #expect {
            try await client.createScaleSet(name: "mac-vm", groupID: 1)
        } throws: { error in
            if case .transient = error as? ScaleSetError { return true }
            return false
        }
    }
}

/// Records each requested sleep and returns at once.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var durations: [Duration] { lock.withLock { recorded } }

    var sleeper: Sleeper {
        { [self] duration in lock.withLock { recorded.append(duration) } }
    }
}
