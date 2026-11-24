import Foundation
@testable import Ghast

/// Records requests and replays queued results. Actor keeps it Sendable.
actor FakeTransport: HTTPTransport {
    enum Reply {
        case json(String, status: Int = 200, headers: [String: String] = [:])
        case failure(Error)
        /// A 200 whose final URL is `url`, as after a redirect to another host.
        case redirected(String, to: String)
        /// Never answers; ends only when the calling task is cancelled.
        case hang
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case let .json(body, status, headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        case let .redirected(body, finalURL):
            let response = HTTPURLResponse(url: URL(string: finalURL)!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(86_400))
            throw CancellationError()
        }
    }
}
