import Foundation

class GitHubAPIService: GitHubAPIServiceProtocol {
    static let shared = GitHubAPIService()

    private static let baseURL = URL(string: "https://api.github.com")!
    private static let apiVersion = "2022-11-28"
    private static let reposPerPage = 100 // Maximum allowed by GitHub API
    private static let maxRepoPages = 50 // Safety limit: 5000 repositories

    private var accessToken: String?
    private let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    func setAccessToken(_ token: String) {
        accessToken = token
    }

    // MARK: - User APIs

    func fetchCurrentUser(token: String? = nil) async throws -> GitHubUser {
        let request = makeRequest(method: "GET", path: "/user", token: token)
        return try await send(request)
    }

    // MARK: - Repository APIs

    func fetchRepositories() async throws -> [GitHubRepository] {
        var allRepositories: [GitHubRepository] = []

        for page in 1...Self.maxRepoPages {
            let request = makeRequest(method: "GET", path: "/user/repos", query: [
                URLQueryItem(name: "type", value: "all"),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(Self.reposPerPage)),
            ])
            let repositories: [GitHubRepository] = try await send(request)
            allRepositories.append(contentsOf: repositories)
            // A short page means we've reached the end
            if repositories.count < Self.reposPerPage { return allRepositories }
        }

        print("⚠️ Repository pagination limit reached (\(Self.maxRepoPages * Self.reposPerPage) repos)")
        return allRepositories
    }

    // MARK: - Runner APIs

    func fetchRunners(for repository: GitHubRepository) async throws -> [GitHubRunner] {
        let request = makeRequest(method: "GET", path: "/repos/\(repository.fullName)/actions/runners")
        let response: RunnersResponse = try await send(request)
        return response.runners
    }

    func fetchOrganizationRunners(org: String) async throws -> [GitHubRunner] {
        let request = makeRequest(method: "GET", path: "/orgs/\(org)/actions/runners")
        let response: RunnersResponse = try await send(request)
        return response.runners
    }

    func createRegistrationToken(for repository: GitHubRepository) async throws -> GitHubRunnerRegistrationToken {
        let request = makeRequest(method: "POST", path: "/repos/\(repository.fullName)/actions/runners/registration-token")
        return try await send(request)
    }

    func createRemoveToken(for repository: GitHubRepository) async throws -> GitHubRunnerRemoveToken {
        let request = makeRequest(method: "POST", path: "/repos/\(repository.fullName)/actions/runners/remove-token")
        return try await send(request)
    }

    func deleteRunner(runnerId: Int, from repository: GitHubRepository) async throws {
        let request = makeRequest(method: "DELETE", path: "/repos/\(repository.fullName)/actions/runners/\(runnerId)")
        _ = try await perform(request)
    }

    func fetchRunnerApplications(for repository: GitHubRepository) async throws -> [GitHubRunnerApplication] {
        let request = makeRequest(method: "GET", path: "/repos/\(repository.fullName)/actions/runners/downloads")
        return try await send(request)
    }

    // MARK: - Transport

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
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }
    }

    /// Sends the request and returns the body of a 2xx response. Cancellation passes
    /// through untouched so callers can tell it apart from a failure.
    private func perform(_ request: URLRequest) async throws -> Data {
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
        return data
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

private struct RunnersResponse: Codable {
    let totalCount: Int
    let runners: [GitHubRunner]
    
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }
}