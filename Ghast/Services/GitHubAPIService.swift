import Foundation
import os

@MainActor
final class GitHubAPIService: GitHubAPIServiceProtocol {
    private static let baseURL = URL(string: "https://api.github.com")!
    private static let apiVersion = "2022-11-28"
    private static let pageSize = 100 // Maximum allowed by GitHub API
    private static let maxPages = 50 // Safety limit: 5000 items per list
    /// Pages fetched at once once GitHub names the last page; kept low to stay clear of
    /// secondary rate limits.
    private static let maxConcurrentPages = 4
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "api")

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
        let user: GitHubUser = try Self.decode(data)
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
        try await fetchAllPages(path: Self.runnersPath(scope), query: []) { (page: RunnersResponse) in page.runners }
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

    func fetchRunnerGroups(org: String) async throws -> [GitHubRunnerGroup] {
        try await fetchAllPages(path: "/orgs/\(org)/actions/runner-groups", query: []) { (page: RunnerGroupsResponse) in page.runnerGroups }
    }

    func generateJITConfig(
        for scope: RunnerScope,
        name: String,
        runnerGroupID: Int,
        labels: [String],
        workFolder: String
    ) async throws -> GitHubJITConfig {
        var request = makeRequest(method: "POST", path: Self.runnersPath(scope, "generate-jitconfig"))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JITConfigRequest(
            name: name, runnerGroupID: runnerGroupID, labels: labels, workFolder: workFolder
        ))
        return try await send(request)
    }

    // MARK: - Workflow APIs

    func fetchWorkflowRuns(repo: String, status: String, etag: String?) async throws -> Conditional<[GitHubWorkflowRun]> {
        let query = [URLQueryItem(name: "status", value: status), URLQueryItem(name: "per_page", value: String(Self.pageSize))]
        let page: Conditional<GitHubWorkflowRunsPage> = try await conditional(path: "/repos/\(repo)/actions/runs", query: query, etag: etag)
        return page.map(\.workflowRuns)
    }

    func fetchJobs(repo: String, runID: Int, etag: String?) async throws -> Conditional<[GitHubWorkflowJob]> {
        let query = [URLQueryItem(name: "per_page", value: String(Self.pageSize))]
        let page: Conditional<GitHubWorkflowJobsPage> = try await conditional(path: "/repos/\(repo)/actions/runs/\(runID)/jobs", query: query, etag: etag)
        return page.map(\.jobs)
    }

    /// A GET with `If-None-Match`; 304 is `.notModified`, other failures throw as usual.
    private func conditional<Page: Decodable & Sendable>(path: String, query: [URLQueryItem], etag: String?) async throws -> Conditional<Page> {
        var request = makeRequest(method: "GET", path: path, query: query)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if error.isCancellation { throw error }
            throw GitHubAPIError.networkError(error)
        }
        if response.statusCode == 304 { return .notModified }
        guard (200..<300).contains(response.statusCode) else { throw Self.error(for: response) }
        return .fresh(try Self.decode(data), etag: response.value(forHTTPHeaderField: "ETag"))
    }

    /// `{scope prefix}/actions/runners[/{suffix}]`.
    private static func runnersPath(_ scope: RunnerScope, _ suffix: String? = nil) -> String {
        let base = "\(scope.apiPathPrefix)/actions/runners"
        return suffix.map { "\(base)/\($0)" } ?? base
    }

    // MARK: - Transport

    /// Fetches every page of a list endpoint (see the enveloped variant).
    private func fetchAllPages<Item: Decodable & Sendable>(path: String, query: [URLQueryItem]) async throws -> [Item] {
        try await fetchAllPages(path: path, query: query) { (page: [Item]) in page }
    }

    /// Paginates an endpoint whose page is an envelope (`{"total_count":…,"runners":[…]}`);
    /// `items` pulls the list out of each page. When the first page's `Link` header names the
    /// last page, the rest are fetched together, `maxConcurrentPages` at a time, and kept in
    /// GitHub's order. Otherwise pages are walked one by one until a short page.
    private func fetchAllPages<Page: Decodable & Sendable, Item>(
        path: String,
        query: [URLQueryItem],
        items extract: (Page) -> [Item]
    ) async throws -> [Item] {
        let (first, response): (Page, HTTPURLResponse) = try await sendForPage(path: path, query: query, page: 1)
        let firstItems = extract(first)
        guard let lastPage = Self.lastPage(fromLinkHeader: response.value(forHTTPHeaderField: "Link")) else {
            return firstItems.count < Self.pageSize
                ? firstItems
                : try await walkPages(from: 2, path: path, query: query, collected: firstItems, items: extract)
        }
        if lastPage > Self.maxPages {
            Self.logger.warning("Pagination limit reached for \(path, privacy: .public) (\(Self.maxPages * Self.pageSize) items)")
        }
        let remaining = lastPage > 1 ? Array(2...min(lastPage, Self.maxPages)) : []
        let pages = try await fetchPages(remaining, path: path, query: query) as [Page]
        return firstItems + pages.flatMap(extract)
    }

    /// Fetches `pages` with at most `maxConcurrentPages` in flight, returned in `pages` order.
    private func fetchPages<Page: Decodable & Sendable>(
        _ pages: [Int],
        path: String,
        query: [URLQueryItem]
    ) async throws -> [Page] {
        try await withThrowingTaskGroup(of: (Int, Page).self) { group in
            var results: [Int: Page] = [:]
            var next = 0
            while next < pages.count || !group.isEmpty {
                while next < pages.count, next - results.count < Self.maxConcurrentPages {
                    let page = pages[next]
                    let request = pageRequest(path: path, query: query, page: page)
                    let transport = transport
                    group.addTask {
                        let (data, _) = try await Self.perform(request, on: transport)
                        let decoded: Page = try Self.decode(data)
                        return (page, decoded)
                    }
                    next += 1
                }
                if let (page, result) = try await group.next() {
                    results[page] = result
                }
            }
            return pages.compactMap { results[$0] }
        }
    }

    /// Follows `page`/`per_page` pagination until a short page or the safety limit.
    private func walkPages<Page: Decodable & Sendable, Item>(
        from start: Int,
        path: String,
        query: [URLQueryItem],
        collected: [Item],
        items extract: (Page) -> [Item]
    ) async throws -> [Item] {
        var items = collected
        for page in start...Self.maxPages {
            let pageItems = extract(try await sendForPage(path: path, query: query, page: page).page as Page)
            items.append(contentsOf: pageItems)
            // A short page means we've reached the end
            if pageItems.count < Self.pageSize { return items }
        }
        Self.logger.warning("Pagination limit reached for \(path, privacy: .public) (\(Self.maxPages * Self.pageSize) items)")
        return items
    }

    private func sendForPage<Page: Decodable>(
        path: String,
        query: [URLQueryItem],
        page: Int
    ) async throws -> (page: Page, response: HTTPURLResponse) {
        let (data, response) = try await perform(pageRequest(path: path, query: query, page: page))
        return (try Self.decode(data), response)
    }

    private func pageRequest(path: String, query: [URLQueryItem], page: Int) -> URLRequest {
        makeRequest(method: "GET", path: path, query: query + [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(Self.pageSize)),
        ])
    }

    /// The `page` of the `rel="last"` link in a GitHub `Link` header, if there is one.
    static func lastPage(fromLinkHeader header: String?) -> Int? {
        guard let header else { return nil }
        for link in header.split(separator: ",") {
            let parts = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.dropFirst().contains(#"rel="last""#),
                  let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  let components = URLComponents(string: String(target.dropFirst().dropLast())),
                  let page = components.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init)
            else { continue }
            return page
        }
        return nil
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
        try Self.decode(try await perform(request).data)
    }

    private nonisolated static func decode<Response: Decodable>(_ data: Data) throws -> Response {
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
        try await Self.perform(request, on: transport)
    }

    private nonisolated static func perform(
        _ request: URLRequest,
        on transport: any HTTPTransport
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if error.isCancellation { throw error }
            throw GitHubAPIError.networkError(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response)
        }
        return (data, response)
    }

    /// A 403 or 429 is a rate limit when GitHub says when to come back: `Retry-After`
    /// (secondary limits), or `X-RateLimit-Reset` once `X-RateLimit-Remaining` is 0. A 429
    /// is always one.
    private nonisolated static func error(for response: HTTPURLResponse) -> GitHubAPIError {
        let status = response.statusCode
        guard status == 403 || status == 429 else { return error(forStatus: status) }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let exhausted = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
        let resetAt = exhausted
            ? response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            : nil
        guard status == 429 || retryAfter != nil || resetAt != nil else { return error(forStatus: status) }
        return .rateLimited(status: status, retryAfter: retryAfter, resetAt: resetAt)
    }

    private nonisolated static func error(forStatus status: Int) -> GitHubAPIError {
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

private struct OrganizationMembership: Decodable, Sendable {
    let role: String
    let organization: GitHubOrganization
}

private struct RunnersResponse: Codable, Sendable {
    let totalCount: Int
    let runners: [GitHubRunner]
    
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }
}

private struct RunnerGroupsResponse: Decodable, Sendable {
    let runnerGroups: [GitHubRunnerGroup]

    enum CodingKeys: String, CodingKey {
        case runnerGroups = "runner_groups"
    }
}

private struct JITConfigRequest: Encodable, Sendable {
    let name: String
    let runnerGroupID: Int
    let labels: [String]
    let workFolder: String

    enum CodingKeys: String, CodingKey {
        case name, labels
        case runnerGroupID = "runner_group_id"
        case workFolder = "work_folder"
    }
}
