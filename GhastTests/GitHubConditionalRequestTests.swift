import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct GitHubConditionalRequestTests {
    static let runsJSON = #"{"total_count":2,"workflow_runs":[{"id":5,"status":"queued","name":"CI"},{"id":6,"status":"queued"}]}"#
    static let jobsJSON = #"{"total_count":2,"jobs":[{"id":50,"status":"queued","labels":["mac-vm"]},{"id":51,"status":"in_progress","labels":["ubuntu-latest"]}]}"#

    private func makeService(_ replies: [FakeTransport.Reply]) -> (GitHubAPIService, FakeTransport) {
        let transport = FakeTransport(replies)
        let service = GitHubAPIService(transport: transport)
        service.setAccessToken("tok")
        return (service, transport)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("runs are fetched by status and come back with their ETag")
    func runs() async throws {
        let (service, transport) = makeService([.json(Self.runsJSON, headers: ["ETag": #"W/"abc""#])])
        let result = try await service.fetchWorkflowRuns(repo: "octo/ghast", status: "queued", etag: nil)
        guard case let .fresh(runs, etag) = result else { Issue.record("expected fresh"); return }
        #expect(runs.map(\.id) == [5, 6])
        #expect(etag == #"W/"abc""#)
        let request = await transport.requests[0]
        #expect(request.url?.path == "/repos/octo/ghast/actions/runs")
        #expect(query(request) == ["status": "queued", "per_page": "100"])
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("a known ETag is sent and 304 means not modified")
    func notModified() async throws {
        let (service, transport) = makeService([.json("", status: 304)])
        let result = try await service.fetchWorkflowRuns(repo: "octo/ghast", status: "in_progress", etag: #"W/"abc""#)
        guard case .notModified = result else { Issue.record("expected notModified"); return }
        #expect(await transport.requests[0].value(forHTTPHeaderField: "If-None-Match") == #"W/"abc""#)
    }

    @Test("a run's jobs decode with their labels")
    func jobs() async throws {
        let (service, transport) = makeService([.json(Self.jobsJSON, headers: ["ETag": "j1"])])
        let result = try await service.fetchJobs(repo: "octo/ghast", runID: 5, etag: nil)
        guard case let .fresh(jobs, etag) = result else { Issue.record("expected fresh"); return }
        #expect(jobs == [
            GitHubWorkflowJob(id: 50, status: "queued", labels: ["mac-vm"]),
            GitHubWorkflowJob(id: 51, status: "in_progress", labels: ["ubuntu-latest"]),
        ])
        #expect(etag == "j1")
        #expect(await transport.requests[0].url?.path == "/repos/octo/ghast/actions/runs/5/jobs")
    }

    @Test("other failures still throw")
    func failure() async throws {
        let (service, _) = makeService([.json("", status: 500)])
        await #expect(throws: GitHubAPIError.self) {
            try await service.fetchJobs(repo: "octo/ghast", runID: 5, etag: "x")
        }
    }
}
