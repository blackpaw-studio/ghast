import Foundation

/// A request forwarded to GitHub's results service.
struct ForwardRequest: Sendable {
    let method: String
    let url: URL
    let headers: [(String, String)]
    let body: Data
}

struct ForwardResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: AsyncThrowingStream<Data, Error>
}

protocol UpstreamForwarding: Sendable {
    func forward(_ request: ForwardRequest) async throws -> ForwardResponse
}

/// Sends every non-cache call the job makes to `ACTIONS_RESULTS_URL` (artifacts, step
/// summaries, attestations) on to GitHub's results service. The target is only ever a path
/// and query appended to the fixed base, so a job can't make Ghast reach another host, and
/// cache methods are never forwarded. Request bodies are Twirp JSON, buffered up to a cap.
struct CachePassthrough: Sendable {
    static let defaultBase = URL(string: "https://results-receiver.actions.githubusercontent.com")!
    let upstream: any UpstreamForwarding
    var base = CachePassthrough.defaultBase
    var maximumBodyBytes = 8 * 1024 * 1024

    private static let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection", "te", "trailer",
        "trailers", "transfer-encoding", "upgrade", "host", "content-length",
    ]
    private static let cachePathPrefix = "/twirp/" + CacheTwirp.servicePrefix.lowercased().dropLast()

    func handle(method: String, target: String, headers: [(String, String)],
                body: AsyncThrowingStream<Data, Error>) async -> ForwardResponse {
        guard let url = upstreamURL(target) else { return Self.error(400, "malformed", "invalid request target") }
        guard !Self.isCacheMethod(url) else { return Self.error(404, "bad_route", "no such method") }
        let data: Data
        do {
            guard let collected = try await collect(body) else {
                return Self.error(413, "resource_exhausted", "request too large")
            }
            data = collected
        } catch {
            return Self.error(400, "malformed", "incomplete request body")
        }
        let request = ForwardRequest(method: method, url: url, headers: Self.endToEnd(headers), body: data)
        do {
            let response = try await upstream.forward(request)
            return ForwardResponse(status: response.status, headers: Self.endToEnd(response.headers), body: response.body)
        } catch {
            return Self.error(502, "unavailable", "results service unreachable")
        }
    }

    /// `base` plus the target's path and query, or nil for anything that isn't a plain
    /// origin-form target (absolute or scheme-relative forms, backslashes, fragments, dot
    /// segments) or that would resolve to another scheme, host or port.
    private func upstreamURL(_ target: String) -> URL? {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("\\"), !target.contains("#"),
              target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.removingPercentEncoding ?? String($0) }
        guard !segments.contains(where: { $0 == "." || $0 == ".." || $0.contains("/") && $0.contains("..") }) else { return nil }
        let baseText = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        guard let url = URL(string: baseText + target), url.scheme == base.scheme, url.host == base.host,
              url.port == base.port else { return nil }
        return url
    }

    /// True for any spelling of a `CacheService` method, percent-encoded or not.
    private static func isCacheMethod(_ url: URL) -> Bool {
        let path = (url.path(percentEncoded: true).removingPercentEncoding ?? url.path).lowercased()
        return path.hasPrefix(cachePathPrefix)
    }

    /// Drops hop-by-hop headers, `Host`, `Content-Length` and any header `Connection` names.
    private static func endToEnd(_ headers: [(String, String)]) -> [(String, String)] {
        let named = headers.filter { $0.0.lowercased() == "connection" }
            .flatMap { $0.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        let dropped = hopByHop.union(named)
        return headers.filter { !dropped.contains($0.0.lowercased()) }
    }

    /// The whole body, or nil once it passes the cap.
    private func collect(_ body: AsyncThrowingStream<Data, Error>) async throws -> Data? {
        var data = Data()
        for try await chunk in body {
            guard data.count + chunk.count <= maximumBodyBytes else { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func error(_ status: Int, _ code: String, _ message: String) -> ForwardResponse {
        let body = CacheTwirpService.error(status, code, message).body
        return ForwardResponse(status: status, headers: [("Content-Type", "application/json")],
                               body: AsyncThrowingStream { $0.yield(body); $0.finish() })
    }
}

/// Forwards with an ephemeral URLSession (no cookies, no cache) and streams the reply back
/// in chunks. Redirects are relayed to the job, never followed, so the request (and its
/// token) only ever goes to the results service. Asks for an identity encoding so the
/// relayed bytes match the upstream headers.
struct URLSessionUpstream: UpstreamForwarding {
    let session: URLSession
    var chunkBytes = 64 * 1024

    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    func forward(_ request: ForwardRequest) async throws -> ForwardResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        request.headers.forEach { urlRequest.addValue($0.1, forHTTPHeaderField: $0.0) }
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !request.body.isEmpty { urlRequest.httpBody = request.body }
        let (bytes, response) = try await session.bytes(for: urlRequest, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let headers = http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let name = key as? String, name.lowercased() != "content-encoding" else { return nil }
            return (name, "\(value)")
        }
        return ForwardResponse(status: http.statusCode, headers: headers, body: Self.chunked(bytes, size: chunkBytes))
    }

    private static func chunked(_ bytes: URLSession.AsyncBytes, size: Int) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= size {
                            continuation.yield(buffer)
                            buffer = Data()
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
