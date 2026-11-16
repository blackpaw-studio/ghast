import Foundation

@MainActor
final class GitHubAPIService: GitHubAPIServiceProtocol {
    private static let baseURL = URL(string: "https://api.github.com")!
    private static let apiVersion = "2022-11-28"
    private static let pageSize = 100 // Maximum allowed by GitHub API
    private static let maxPages = 50 // Safety limit: 5000 items per list

    private var accessToken: String?
    private let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    func setAccessToken(_ token: String) {
        accessToken = token
    }

    // MARK: - User APIs

    func fetchCurrentUser(token: String? = nil) async throws -> AuthenticatedUser {
        let request = makeRequest(method: "GET", path: "/user", token: token)
        let (data, response) = try await perform(request)
        let user: GitHubUser = try decode(data)
        let scopes = AuthenticatedUser.scopes(fromHeader: response.value(forHTTPHeaderField: "X-OAuth-Scopes"))
        return AuthenticatedUser(user: user, grantedScopes: scopes)
    }

    // MARK: - Repository APIs

    func fetchRepositories() async throws -> [GitHubRepository] {
        try await fetchAllPages(path: "/user/repos", query: [
            URLQueryItem(name: "type", value: "all"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
        ])
    }

    // MARK: - Organization APIs

    /// Active organization memberships where the user is an admin (owner).
    func fetchAdminOrganizations() async throws -> [GitHubOrganization] {
        let memberships: [OrganizationMembership] = try await fetchAllPages(
            path: "/user/memberships/orgs",
            query: [URLQueryItem(name: "state", value: "active")]
        )
        return memberships.filter { $0.role == "admin" }.map(\.organization)
    }

    // MARK: - Runner APIs

    func fetchRunners(in scope: RunnerScope) async throws -> [GitHubRunner] {
        let request = makeRequest(method: "GET", path: Self.runnersPath(scope))
        let response: RunnersResponse = try await send(request)
        return response.runners
    }

    func createRegistrationToken(for scope: RunnerScope) async throws -> GitHubRunnerRegistrationToken {
        let request = makeRequest(method: "POST", path: Self.runnersPath(scope, "registration-token"))
        return try await send(request)
    }

    func createRemoveToken(for scope: RunnerScope) async throws -> GitHubRunnerRemoveToken {
        let request = makeRequest(method: "POST", path: Self.runnersPath(scope, "remove-token"))
        return try await send(request)
    }

    func deleteRunner(runnerId: Int, from scope: RunnerScope) async throws {
        let request = makeRequest(method: "DELETE", path: Self.runnersPath(scope, String(runnerId)))
        _ = try await perform(request)
    }

    func fetchRunnerApplications(for scope: RunnerScope) async throws -> [GitHubRunnerApplication] {
        let request = makeRequest(method: "GET", path: Self.runnersPath(scope, "downloads"))
        return try await send(request)
    }

    /// `{scope prefix}/actions/runners[/{suffix}]`.
    private static func runnersPath(_ scope: RunnerScope, _ suffix: String? = nil) -> String {
        let base = "\(scope.apiPathPrefix)/actions/runners"
        return suffix.map { "\(base)/\($0)" } ?? base
    }

    // MARK: - Transport

    /// Follows `page`/`per_page` pagination until a short page or the safety limit.
    private func fetchAllPages<Item: Decodable>(path: String, query: [URLQueryItem]) async throws -> [Item] {
        var items: [Item] = []
        for page in 1...Self.maxPages {
            let request = makeRequest(method: "GET", path: path, query: query + [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(Self.pageSize)),
            ])
            let pageItems: [Item] = try await send(request)
            items.append(contentsOf: pageItems)
            // A short page means we've reached the end
            if pageItems.count < Self.pageSize { return items }
        }

        print("⚠️ Pagination limit reached for \(path) (\(Self.maxPages * Self.pageSize) items)")
        return items
    }

    /// Every request carries `Accept` and the API version; `Authorization` only when a
    /// token is available (explicit `token` wins over the stored one).
    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        token: String? = nil
    ) -> URLRequest {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = token ?? accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        try decode(try await perform(request).data)
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }
    }

    /// Sends the request and returns the body and response of a 2xx reply. Cancellation
    /// passes through untouched so callers can tell it apart from a failure.
    @discardableResult
    private func perform(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if error.isCancellation { throw error }
            throw GitHubAPIError.networkError(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(forStatus: response.statusCode)
        }
        return (data, response)
    }

    private static func error(forStatus status: Int) -> GitHubAPIError {
        switch status {
        case 401: .unauthorized
        case 404: .notFound
        case 500...599: .serverError(status)
        default: .httpStatus(status)
        }
    }
}

extension Error {
    /// True for task cancellation, however it surfaced (Swift concurrency or URLSession).
    /// Views must not show this as a failure.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

private struct OrganizationMembership: Decodable {
    let role: String
    let organization: GitHubOrganization
}

private struct RunnersResponse: Codable {
    let totalCount: Int
    let runners: [GitHubRunner]
    
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }
}