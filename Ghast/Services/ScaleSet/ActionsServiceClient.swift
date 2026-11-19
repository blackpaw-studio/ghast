import Foundation
import os

/// Talks to GitHub's Actions service for one runner scope, the way
/// github.com/actions/scaleset @ 716908e does (`client.go`):
/// 1. a registration token from the REST API (the user's OAuth token),
/// 2. `POST /actions/runner-registration` with `RemoteAuth <registration token>`, which
///    returns the service URL and an admin JWT,
/// 3. service calls under `<url>/<path>?api-version=6.0-preview` with `Bearer <JWT>`,
///    refreshing the JWT 60 s before its `exp`.
@MainActor
final class ActionsServiceClient {
    /// Retries of `runner-registration` on 401/403 (a fresh registration token is "not always
    /// usable immediately"), with the reference's backoff: 1 s doubling, capped at 30 s.
    struct RetryPolicy: Sendable {
        var maxRetries = 4
        var waitMin: Duration = .seconds(1)
        var waitMax: Duration = .seconds(30)

        func wait(beforeRetry attempt: Int) -> Duration {
            min(waitMin * (1 << min(attempt - 1, 16)), waitMax)
        }
    }

    static let scaleSetsPath = "_apis/runtime/runnerscalesets"
    static let apiVersion = "6.0-preview"
    private static let registrationURL = URL(string: "https://api.github.com/actions/runner-registration")!
    /// Refresh the admin token once it has less than this left.
    private static let refreshMargin: TimeInterval = 60
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "scaleset")

    struct Connection: Sendable {
        let serviceURL: String
        let token: String
        let expiresAt: Date
    }

    let scope: RunnerScope
    private let api: any GitHubAPIServiceProtocol
    private let transport: any HTTPTransport
    private let clock: any AppClock
    private let sleeper: Sleeper
    private let retry: RetryPolicy
    private var connection: Connection?
    private var refresh: Task<Connection, any Error>?

    init(
        scope: RunnerScope,
        api: any GitHubAPIServiceProtocol,
        transport: any HTTPTransport,
        clock: any AppClock,
        sleeper: @escaping Sleeper,
        retry: RetryPolicy = RetryPolicy()
    ) {
        self.scope = scope
        self.api = api
        self.transport = transport
        self.clock = clock
        self.sleeper = sleeper
        self.retry = retry
    }

    // MARK: - Scale sets

    /// The set with `name` in the group, or nil. Several sets with one name is an error.
    func scaleSet(named name: String, groupID: Int) async throws -> ScaleSet? {
        let data = try await send("GET", Self.scaleSetsPath, query: [
            URLQueryItem(name: "runnerGroupId", value: String(groupID)),
            URLQueryItem(name: "name", value: name),
        ], expecting: 200)
        return try Self.decode(ScaleSetList.self, data).single()
    }

    func createScaleSet(name: String, groupID: Int) async throws -> ScaleSet {
        let body = try JSONEncoder().encode(ScaleSetCreateRequest(name: name, runnerGroupID: groupID))
        let data = try await send("POST", Self.scaleSetsPath, body: body, expecting: 200)
        return try Self.decode(ScaleSet.self, data)
    }

    /// Deletes the set; one that is already gone (404) counts as deleted.
    func deleteScaleSet(id: Int) async throws {
        do {
            _ = try await send("DELETE", "\(Self.scaleSetsPath)/\(id)", expecting: 204)
        } catch ScaleSetError.notFound {
            return
        }
    }

    /// Registers a one-job runner in the set. The config is a credential; never logged.
    func jitConfig(scaleSetID: Int, name: String, workFolder: String) async throws -> GitHubJITConfig {
        let body = try JSONEncoder().encode(["name": name, "workFolder": workFolder])
        let data = try await send("POST", "\(Self.scaleSetsPath)/\(scaleSetID)/generatejitconfig", body: body, expecting: 200)
        return try Self.decode(ScaleSetJITConfig.self, data).jit
    }

    // MARK: - Service requests

    /// A service call that must answer `expecting`; any other status throws its `ScaleSetError`.
    /// `bearer` replaces the admin token (acquire-jobs uses the message queue token).
    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        bearer: String? = nil,
        expecting status: Int
    ) async throws -> Data {
        let (data, response) = try await sendRaw(method, path, query: query, body: body, bearer: bearer)
        guard response.statusCode == status else {
            throw Self.error(for: response, body: data, now: clock.now())
        }
        return data
    }

    /// A service call whose status the caller judges; only transport failures throw.
    func sendRaw(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        bearer: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let connection = try await currentConnection()
        var request = URLRequest(url: try Self.serviceURL(connection.serviceURL, path: path, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer ?? connection.token)", forHTTPHeaderField: "Authorization")
        return try await Self.transmit(request, on: transport)
    }

    /// `<base>/<path>` with `api-version` added unless the path names one (`requestURL`).
    static func serviceURL(_ base: String, path: String, query: [URLQueryItem]) throws -> URL {
        let (pathOnly, pathQuery) = splitQuery(path)
        let joined = base.trimmingTrailingSlashes() + "/" + pathOnly.trimmingLeadingSlashes()
        guard var components = URLComponents(string: joined) else { throw ScaleSetError.badResponse("service URL \(joined)") }
        var items = pathQuery + query
        if !items.contains(where: { $0.name == "api-version" }) {
            items.append(URLQueryItem(name: "api-version", value: apiVersion))
        }
        components.queryItems = items
        guard let url = components.url else { throw ScaleSetError.badResponse("service URL \(joined)") }
        return url
    }

    private static func splitQuery(_ path: String) -> (String, [URLQueryItem]) {
        guard let mark = path.firstIndex(of: "?") else { return (path, []) }
        let items = URLComponents(string: "x:/?" + path[path.index(after: mark)...])?.queryItems ?? []
        return (String(path[..<mark]), items)
    }

    /// Sends one request; transport failures become `.transient`, cancellation passes through.
    nonisolated static func transmit(_ request: URLRequest, on transport: any HTTPTransport) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            if error.isCancellation { throw error }
            throw ScaleSetError.transient(error.localizedDescription)
        }
    }

    // MARK: - Admin connection

    /// The cached connection while it has more than a minute left; otherwise one shared refresh.
    private func currentConnection() async throws -> Connection {
        if let connection, clock.now().addingTimeInterval(Self.refreshMargin) < connection.expiresAt {
            return connection
        }
        if let refresh { return try await refresh.value }
        let task = Task { try await self.handshake() }
        refresh = task
        defer { refresh = nil }
        let fresh = try await task.value
        connection = fresh
        return fresh
    }

    private func handshake() async throws -> Connection {
        // A refused OAuth token here is the existing auth error (REST would fail too).
        let registration = try await api.createRegistrationToken(for: scope)
        var request = URLRequest(url: Self.registrationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RemoteAuth \(registration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["url": scope.configURL, "runner_event": "register"])

        var attempt = 0
        while true {
            let (data, response) = try await Self.transmit(request, on: transport)
            if (200..<300).contains(response.statusCode) {
                return try Self.connection(from: data)
            }
            let error = Self.error(for: response, body: data, now: clock.now())
            guard error == .authRejected, attempt < retry.maxRetries else { throw error }
            attempt += 1
            Self.logger.notice("runner-registration answered \(response.statusCode); retry \(attempt)")
            try await sleeper(retry.wait(beforeRetry: attempt))
        }
    }

    private static func connection(from data: Data) throws -> Connection {
        let reply = try decode(ActionsServiceConnection.self, data)
        guard let url = reply.url, !url.isEmpty else { throw ScaleSetError.badResponse("admin connection missing url") }
        guard let token = reply.token, !token.isEmpty else { throw ScaleSetError.badResponse("admin connection missing token") }
        return Connection(serviceURL: url, token: token, expiresAt: try expiry(ofJWT: token))
    }

    /// `exp` from the JWT's payload, read without verifying the signature.
    static func expiry(ofJWT token: String) throws -> Date {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ScaleSetError.badResponse("admin token is not a JWT") }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? NSNumber
        else { throw ScaleSetError.badResponse("admin token missing expiration") }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    // MARK: - Errors

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ScaleSetError.badResponse("\(type): \(error.localizedDescription)")
        }
    }

    /// Maps a failure the way `errors.go` does: rate limits first (429, or a 403 with
    /// `Retry-After`, `X-RateLimit-Remaining: 0` or a "secondary rate" message), then 400,
    /// 401/403, 404, 409; 5xx other than 501 is transient.
    nonisolated static func error(for response: HTTPURLResponse, body: Data, now: Date) -> ScaleSetError {
        let status = response.statusCode
        let exception = ActionsException.parse(body)
        let message = exception?.message ?? String(decoding: body, as: UTF8.self)
        if let rateLimit = rateLimit(response, message: message, now: now) { return rateLimit }
        switch status {
        case 400: return .badRequest(message.isEmpty ? "HTTP 400" : message)
        case 401, 403: return .authRejected
        case 404: return .notFound
        case 409: return .conflict
        case 500...599 where status != 501: return .transient("HTTP \(status)")
        default: return .badResponse(message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)")
        }
    }

    private nonisolated static func rateLimit(_ response: HTTPURLResponse, message: String, now: Date) -> ScaleSetError? {
        let header = { (name: String) in response.value(forHTTPHeaderField: name) }
        let primary = header("X-RateLimit-Remaining") == "0"
        let secondary = message.range(of: #"\bsecondary rate\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let retryAfter = header("Retry-After").flatMap(TimeInterval.init)
        switch response.statusCode {
        case 429: break
        case 403 where primary || secondary || retryAfter != nil: break
        default: return nil
        }
        if let retryAfter { return .rateLimited(retryAfter: retryAfter) }
        let reset = primary ? header("X-RateLimit-Reset").flatMap(TimeInterval.init) : nil
        return .rateLimited(retryAfter: reset.map { max(0, $0 - now.timeIntervalSince1970) })
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var text = self
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func trimmingLeadingSlashes() -> String {
        String(drop { $0 == "/" })
    }
}
