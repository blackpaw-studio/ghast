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
