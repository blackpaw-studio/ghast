import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct GitHubAPIServiceRequestTests {
    static let userJSON = #"{"id":1,"login":"octocat","avatar_url":"https://a/1","name":null,"email":null}"#
    static let repoJSON = """
    {"id":7,"name":"ghast","full_name":"octo/ghast","description":null,"private":false,"owner":\(userJSON),"html_url":"https://github.com/octo/ghast"}
    """
    static let runnerJSON = #"{"id":42,"name":"r1","os":"macOS","status":"online","busy":false,"labels":[{"id":1,"name":"self-hosted","type":"read-only"}]}"#
    static let tokenJSON = #"{"token":"AAA","expires_at":"2026-01-01T00:00:00Z"}"#

    func makeService(_ replies: [FakeTransport.Reply], token: String? = "tok") -> (GitHubAPIService, FakeTransport) {
        let transport = FakeTransport(replies)
        let service = GitHubAPIService(transport: transport)
        if let token { service.setAccessToken(token) }
        return (service, transport)
    }

    func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func expectStandardHeaders(_ request: URLRequest, token: String = "tok") {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    // MARK: Endpoints

    @Test func fetchCurrentUserUsesStoredToken() async throws {
        let (service, transport) = makeService([.json(Self.userJSON)])

        let user = try await service.fetchCurrentUser(token: nil)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        expectStandardHeaders(request)
        #expect(user.login == "octocat")
    }

    @Test func fetchCurrentUserWithExplicitTokenSendsThatToken() async throws {
        let (service, transport) = makeService([.json(Self.userJSON)], token: nil)

        _ = try await service.fetchCurrentUser(token: "x")

        expectStandardHeaders(try #require(await transport.requests.first), token: "x")
    }

    @Test func fetchRepositoriesSendsListQuery() async throws {
        let (service, transport) = makeService([.json("[\(Self.repoJSON)]")])

        let repos = try await service.fetchRepositories()

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/user/repos")
        #expect(query(request) == ["type": "all", "sort": "updated", "direction": "desc", "page": "1", "per_page": "100"])
        expectStandardHeaders(request)
        #expect(repos.map(\.fullName) == ["octo/ghast"])
    }

    @Test func fetchRepositoriesPaginatesUntilShortPage() async throws {
        let fullPage = "[" + Array(repeating: Self.repoJSON, count: 100).joined(separator: ",") + "]"
        let (service, transport) = makeService([.json(fullPage), .json("[\(Self.repoJSON)]")])

        let repos = try await service.fetchRepositories()

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(query(requests[1])["page"] == "2")
        #expect(repos.count == 101)
    }

    nonisolated static let scopes: [RunnerScope] = [.repository(fullName: "octo/ghast"), .organization(login: "acme")]

    func base(_ scope: RunnerScope) -> String {
        switch scope {
        case .repository: "https://api.github.com/repos/octo/ghast"
        case .organization: "https://api.github.com/orgs/acme"
        }
    }

    @Test(arguments: scopes)
    func fetchRunnersUnwrapsRunnersList(scope: RunnerScope) async throws {
        let (service, transport) = makeService([.json(#"{"total_count":1,"runners":[\#(Self.runnerJSON)]}"#)])

        let runners = try await service.fetchRunners(in: scope)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "\(base(scope))/actions/runners")
        expectStandardHeaders(request)
        #expect(runners.map(\.id) == [42])
    }

    @Test(arguments: scopes)
    func createRegistrationTokenPosts(scope: RunnerScope) async throws {
        let (service, transport) = makeService([.json(Self.tokenJSON, status: 201)])

        let token = try await service.createRegistrationToken(for: scope)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(base(scope))/actions/runners/registration-token")
        expectStandardHeaders(request)
        #expect(token.token == "AAA")
    }

    @Test(arguments: scopes)
    func createRemoveTokenPosts(scope: RunnerScope) async throws {
        let (service, transport) = makeService([.json(Self.tokenJSON, status: 201)])

        let token = try await service.createRemoveToken(for: scope)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(base(scope))/actions/runners/remove-token")
        expectStandardHeaders(request)
        #expect(token.token == "AAA")
    }

    @Test(arguments: scopes)
    func deleteRunnerSendsDeleteAndAcceptsEmptyBody(scope: RunnerScope) async throws {
        let (service, transport) = makeService([.json("", status: 204)])

        try await service.deleteRunner(runnerId: 42, from: scope)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "\(base(scope))/actions/runners/42")
        expectStandardHeaders(request)
    }

    @Test(arguments: scopes)
    func fetchRunnerApplicationsDecodesList(scope: RunnerScope) async throws {
        let body = #"[{"os":"osx","architecture":"arm64","download_url":"https://d/x.tar.gz","filename":"x.tar.gz"}]"#
        let (service, transport) = makeService([.json(body)])

        let apps = try await service.fetchRunnerApplications(for: scope)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "\(base(scope))/actions/runners/downloads")
        expectStandardHeaders(request)
        #expect(apps.map(\.architecture) == ["arm64"])
    }

    // MARK: Organizations

    static func membershipJSON(login: String, id: Int, role: String) -> String {
        #"{"state":"active","role":"\#(role)","organization":{"login":"\#(login)","id":\#(id),"avatar_url":"https://a/\#(id)"}}"#
    }

    @Test func fetchAdminOrganizationsKeepsOnlyAdminMemberships() async throws {
        let body = "[" + [
            Self.membershipJSON(login: "acme", id: 1, role: "admin"),
            Self.membershipJSON(login: "other", id: 2, role: "member"),
            Self.membershipJSON(login: "zeta", id: 3, role: "admin"),
        ].joined(separator: ",") + "]"
        let (service, transport) = makeService([.json(body)])

        let orgs = try await service.fetchAdminOrganizations()

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/user/memberships/orgs")
        #expect(query(request) == ["state": "active", "per_page": "100", "page": "1"])
        expectStandardHeaders(request)
        #expect(orgs == [
            GitHubOrganization(login: "acme", id: 1, avatarURL: "https://a/1"),
            GitHubOrganization(login: "zeta", id: 3, avatarURL: "https://a/3"),
        ])
    }

    @Test func fetchAdminOrganizationsPaginatesUntilShortPage() async throws {
        let membership = Self.membershipJSON(login: "acme", id: 1, role: "admin")
        let fullPage = "[" + Array(repeating: membership, count: 100).joined(separator: ",") + "]"
        let (service, transport) = makeService([.json(fullPage), .json("[\(membership)]")])

        let orgs = try await service.fetchAdminOrganizations()

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(query(requests[1])["page"] == "2")
        #expect(orgs.count == 101)
    }

    @Test func requestWithoutTokenOmitsAuthorizationButKeepsOtherHeaders() async throws {
        let (service, transport) = makeService([.json(Self.userJSON)], token: nil)

        _ = try await service.fetchCurrentUser(token: nil)

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    // MARK: Errors

    @Test(arguments: [401, 404, 503, 403, 422])
    func non2xxStatusMapsToTypedErrorCarryingCode(status: Int) async {
        let (service, _) = makeService([.json("{}", status: status)])

        await #expect {
            try await service.fetchCurrentUser(token: nil)
        } throws: { error in
            guard let error = error as? GitHubAPIError, error.statusCode == status else { return false }
            switch (status, error) {
            case (401, .unauthorized), (404, .notFound), (503, .serverError(503)): return true
            case (403, .httpStatus(403)), (422, .httpStatus(422)): return true
            default: return false
            }
        }
    }

    @Test func undecodableSuccessBodyIsDecodingError() async {
        let (service, _) = makeService([.json("not json")])

        await #expect {
            try await service.fetchCurrentUser(token: nil)
        } throws: { error in
            guard case .decodingError = error as? GitHubAPIError else { return false }
            return true
        }
    }

    @Test func transportFailureIsNetworkError() async {
        let (service, _) = makeService([.failure(URLError(.notConnectedToInternet))])

        await #expect {
            try await service.fetchRepositories()
        } throws: { error in
            guard case .networkError = error as? GitHubAPIError else { return false }
            return true
        }
    }

    @Test func cancelledTransportPropagatesCancellation() async {
        let (service, _) = makeService([.failure(URLError(.cancelled))])

        await #expect {
            try await service.fetchRepositories()
        } throws: { error in
            error.isCancellation
        }
    }

    // MARK: Cancellation mapping (views must not surface these)

    @Test func cancellationErrorsAreRecognised() {
        #expect(CancellationError().isCancellation)
        #expect(URLError(.cancelled).isCancellation)
        #expect(!URLError(.timedOut).isCancellation)
        #expect(!GitHubAPIError.unauthorized.isCancellation)
    }
}
