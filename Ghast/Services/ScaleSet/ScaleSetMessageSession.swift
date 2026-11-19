import Foundation

/// The long-poll message session of one scale set (`session_client.go` @ 716908e).
/// Queue calls carry the session's `messageQueueAccessToken`; a 401 on any of them refreshes
/// the session (`PATCH`) and retries once.
@MainActor
final class ScaleSetMessageSession {
    /// The server holds a poll for about 50 s; the reference caps an attempt at 120 s.
    static let pollTimeout: TimeInterval = 120
    static let maxCapacity = 2

    private let client: ActionsServiceClient
    private let scaleSetID: Int
    private let transport: any HTTPTransport
    private(set) var session: ScaleSetSession?

    init(client: ActionsServiceClient, scaleSetID: Int, transport: any HTTPTransport) {
        self.client = client
        self.scaleSetID = scaleSetID
        self.transport = transport
    }

    private var sessionsPath: String { "\(ActionsServiceClient.scaleSetsPath)/\(scaleSetID)/sessions" }

    /// Opens the session. A 409 means another listener (another Mac, or a crashed run whose
    /// session has not expired) holds it.
    @discardableResult
    func create(ownerName: String) async throws -> ScaleSetSession {
        let body = try JSONEncoder().encode(["ownerName": ownerName])
        let data = try await client.send("POST", sessionsPath, body: body, expecting: 200)
        let created = try Self.decodeSession(data)
        session = created
        return created
    }

    /// The next message after `lastID`, or nil when the poll ended with none (202).
    func nextMessage(lastID: Int) async throws -> ScaleSetMessage? {
        try await withRefresh { session in
            var components = try Self.components(session.messageQueueURL)
            if lastID > 0 {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "lastMessageId", value: String(lastID))]
            }
            var request = URLRequest(url: try Self.url(components), timeoutInterval: Self.pollTimeout)
            request.httpMethod = "GET"
            request.setValue("application/json; api-version=\(ActionsServiceClient.apiVersion)", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(session.messageQueueAccessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(String(Self.maxCapacity), forHTTPHeaderField: "X-ScaleSetMaxCapacity")
            let (data, response) = try await ActionsServiceClient.transmit(request, on: self.transport)
            switch response.statusCode {
            case 202: return .done(nil)
            case 200: return .done(try ScaleSetMessage.decode(data))
            case 401: return .unauthorized
            default: throw ActionsServiceClient.error(for: response, body: data, now: self.client.now())
            }
        }
    }

    /// Deletes a handled message from the queue: `<queue path>/<id>`, query kept.
    func ack(id: Int) async throws {
        try await withRefresh { session in
            var components = try Self.components(session.messageQueueURL)
            components.path += "/\(id)"
            var request = URLRequest(url: try Self.url(components))
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.messageQueueAccessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await ActionsServiceClient.transmit(request, on: self.transport)
            switch response.statusCode {
            case 204: return .done(())
            case 401: return .unauthorized
            default: throw ActionsServiceClient.error(for: response, body: data, now: self.client.now())
            }
        }
    }

    /// Claims available jobs for this scale set, which is what gets them assigned to it.
    func acquire(requestIDs: [Int64]) async throws -> [Int64] {
        let body = try JSONEncoder().encode(requestIDs)
        let path = "\(ActionsServiceClient.scaleSetsPath)/\(scaleSetID)/acquirejobs"
        return try await withRefresh { session in
            let (data, response) = try await self.client.sendRaw("POST", path, body: body, bearer: session.messageQueueAccessToken)
            switch response.statusCode {
            case 200:
                guard let acquired = try? JSONDecoder().decode(ScaleSetAcquiredJobs.self, from: data) else {
                    throw ScaleSetError.badResponse("acquire jobs reply")
                }
                return .done(acquired.value)
            case 401: return .unauthorized
            default: throw ActionsServiceClient.error(for: response, body: data, now: self.client.now())
            }
        }
    }

    /// Deletes the session so another listener can take the scale set at once.
    func close() async throws {
        guard let session else { return }
        self.session = nil
        _ = try await client.send("DELETE", "\(sessionsPath)/\(session.sessionID)", expecting: 204)
    }

    // MARK: - Refresh

    private enum Attempt<Value> {
        case done(Value)
        case unauthorized
    }

    /// Runs `attempt` with the current session; on 401 refreshes it and runs once more.
    private func withRefresh<Value>(_ attempt: (ScaleSetSession) async throws -> Attempt<Value>) async throws -> Value {
        guard let current = session else { throw ScaleSetError.badResponse("no message session") }
        if case let .done(value) = try await attempt(current) { return value }
        try await refresh(expired: current)
        guard let fresh = session else { throw ScaleSetError.badResponse("no message session") }
        if case let .done(value) = try await attempt(fresh) { return value }
        throw ScaleSetError.authRejected
    }

    /// `PATCH` the session for a new queue token, unless another call already did.
    private func refresh(expired: ScaleSetSession) async throws {
        guard let current = session,
              current.sessionID == expired.sessionID,
              current.messageQueueAccessToken == expired.messageQueueAccessToken
        else { return }
        let data = try await client.send("PATCH", "\(sessionsPath)/\(current.sessionID)", expecting: 200)
        session = try Self.decodeSession(data)
    }

    private static func decodeSession(_ data: Data) throws -> ScaleSetSession {
        do {
            return try JSONDecoder().decode(ScaleSetSession.self, from: data)
        } catch {
            throw ScaleSetError.badResponse("message session: \(error.localizedDescription)")
        }
    }

    private static func components(_ url: String) throws -> URLComponents {
        guard let components = URLComponents(string: url) else { throw ScaleSetError.badResponse("message queue URL") }
        return components
    }

    private static func url(_ components: URLComponents) throws -> URL {
        guard let url = components.url else { throw ScaleSetError.badResponse("message queue URL") }
        return url
    }
}
