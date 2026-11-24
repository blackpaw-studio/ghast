import Foundation
import Testing
@testable import Ghast

/// Records forwarded requests and replies with a canned status, or throws.
actor FakeUpstream: UpstreamForwarding {
    private(set) var requests: [ForwardRequest] = []
    var status = 200
    var responseBody = Data(#"{"ok":true}"#.utf8)
    var fails = false

    func configure(status: Int = 200, body: String = #"{"ok":true}"#, fails: Bool = false) {
        self.status = status
        responseBody = Data(body.utf8)
        self.fails = fails
    }

    func forward(_ request: ForwardRequest) async throws -> ForwardResponse {
        requests.append(request)
        if fails { throw URLError(.cannotConnectToHost) }
        let body = responseBody
        return ForwardResponse(status: status, headers: [("Content-Type", "application/json"), ("Connection", "close")],
                               body: AsyncThrowingStream { $0.yield(body); $0.finish() })
    }
}

@Suite("Cache passthrough")
struct CachePassthroughTests {
    private let upstream = FakeUpstream()
    private var passthrough: CachePassthrough { CachePassthrough(upstream: upstream) }

    private static func stream(_ text: String, chunk: Int = 4) -> AsyncThrowingStream<Data, Error> {
        let data = Data(text.utf8)
        return AsyncThrowingStream { continuation in
            stride(from: 0, to: data.count, by: chunk).forEach { continuation.yield(data[$0 ..< min($0 + chunk, data.count)]) }
            continuation.finish()
        }
    }

    private static func collect(_ response: ForwardResponse) async throws -> String {
        var data = Data()
        for try await chunk in response.body { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }

    @Test("method, path, query and body reach the results service intact")
    func forwardsIntact() async throws {
        let response = await passthrough.handle(
            method: "POST", target: "/twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact?a=1&b=%2F",
            headers: [("Content-Type", "application/json")], body: Self.stream(#"{"name":"spike"}"#))
        let sent = try #require(await upstream.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString ==
            "https://results-receiver.actions.githubusercontent.com/twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact?a=1&b=%2F")
        #expect(String(decoding: sent.body, as: UTF8.self) == #"{"name":"spike"}"#)
        #expect(response.status == 200)
        #expect(try await Self.collect(response) == #"{"ok":true}"#)
    }

    @Test("hop-by-hop headers and Host are dropped; Authorization is forwarded")
    func headers() async throws {
        let incoming = [("Host", "192.168.64.1:50000"), ("Connection", "keep-alive, X-Private"), ("X-Private", "1"),
                        ("Keep-Alive", "timeout=5"), ("Transfer-Encoding", "chunked"), ("TE", "trailers"),
                        ("Upgrade", "h2c"), ("Proxy-Authorization", "x"), ("Content-Length", "2"),
                        ("Authorization", "Bearer abc"), ("Content-Type", "application/json"), ("User-Agent", "toolkit")]
        let response = await passthrough.handle(method: "POST", target: "/twirp/x.Y/Z", headers: incoming,
                                                body: Self.stream("{}"))
        let sent = try #require(await upstream.requests.first)
        #expect(sent.headers.map { $0.0.lowercased() }.sorted() == ["authorization", "content-type", "user-agent"])
        #expect(!response.headers.contains { $0.0.lowercased() == "connection" })
    }

    @Test("an upstream error status is relayed", arguments: [401, 404, 500, 503])
    func relaysErrors(status: Int) async throws {
        await upstream.configure(status: status, body: #"{"code":"x","msg":"y"}"#)
        let response = await passthrough.handle(method: "POST", target: "/twirp/x.Y/Z", headers: [], body: Self.stream("{}"))
        #expect(response.status == status)
        #expect(try await Self.collect(response) == #"{"code":"x","msg":"y"}"#)
    }

    @Test("an unreachable upstream is a 502 Twirp error")
    func upstreamThrows() async throws {
        await upstream.configure(fails: true)
        let response = await passthrough.handle(method: "POST", target: "/twirp/x.Y/Z", headers: [], body: Self.stream("{}"))
        #expect(response.status == 502)
        let body = try await Self.collect(response)
        #expect((try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["code"] as? String == "unavailable")
    }

    @Test("a target that could reach another host is refused",
          arguments: ["http://evil.example/x", "//evil.example/x", "evil.example/x", "/a/../../x", "/\\evil.example/x",
                      "", "/x#frag", "https:evil.example"])
    func ssrf(target: String) async throws {
        let response = await passthrough.handle(method: "GET", target: target, headers: [], body: Self.stream(""))
        #expect(response.status == 400)
        #expect(await upstream.requests.isEmpty)
    }

    @Test("cache methods are never forwarded", arguments: [
        "/twirp/github.actions.results.api.v1.CacheService/GetCacheEntryDownloadURL",
        "/twirp/GITHUB.ACTIONS.RESULTS.API.V1.CACHESERVICE/CreateCacheEntry",
        "/twirp/github.actions.results.api.v1.CacheService%2FCreateCacheEntry",
        "/twirp/github.actions.results.api.v1.CacheService/CreateCacheEntry?x=1",
    ])
    func neverForwardsCache(target: String) async throws {
        let response = await passthrough.handle(method: "POST", target: target, headers: [], body: Self.stream("{}"))
        #expect(response.status == 404)
        #expect(await upstream.requests.isEmpty)
    }

    @Test("a body over the cap is 413 and isn't forwarded")
    func bodyCap() async throws {
        var capped = passthrough
        capped.maximumBodyBytes = 8
        let response = await capped.handle(method: "POST", target: "/twirp/x.Y/Z", headers: [],
                                           body: Self.stream(String(repeating: "a", count: 9)))
        #expect(response.status == 413)
        #expect(await upstream.requests.isEmpty)
    }

    @Test("the captured artifact calls are forwarded")
    func fixtureReplay() async throws {
        let url = ActionsCacheFixture.folder.appendingPathComponent("passthrough.json")
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try #require(document["requests"] as? [[String: Any]])
        for record in records {
            let method = try #require(record["method"] as? String), path = try #require(record["path"] as? String)
            let response = await passthrough.handle(method: method, target: path, headers: [], body: Self.stream("{}"))
            #expect(response.status == 200)
        }
        #expect(await upstream.requests.map(\.url.path) == records.compactMap { $0["path"] as? String })
    }
}
