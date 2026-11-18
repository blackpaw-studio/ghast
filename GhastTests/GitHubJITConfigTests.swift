import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct GitHubJITConfigTests {
    static let jitJSON = #"{"runner":{"id":77,"name":"vm-1a2b3c","os":"unknown","status":"offline","busy":false,"labels":[]},"encoded_jit_config":"QUJD"}"#

    private func makeService(_ replies: [FakeTransport.Reply]) -> (GitHubAPIService, FakeTransport) {
        let transport = FakeTransport(replies)
        let service = GitHubAPIService(transport: transport)
        service.setAccessToken("tok")
        return (service, transport)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a repository JIT config posts to the repo endpoint and decodes the reply")
    func repositoryRequest() async throws {
        let (service, transport) = makeService([.json(Self.jitJSON, status: 201)])

        let config = try await service.generateJITConfig(
            for: .repository(fullName: "octo/ghast"),
            name: "vm-1a2b3c",
            runnerGroupID: 1,
            labels: ["self-hosted", "macOS"],
            workFolder: "_work"
        )

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/octo/ghast/actions/runners/generate-jitconfig")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(config == GitHubJITConfig(runnerID: 77, encodedConfig: "QUJD"))
    }

    @Test("an organization JIT config posts to the org endpoint")
    func organizationRequest() async throws {
        let (service, transport) = makeService([.json(Self.jitJSON, status: 201)])

        _ = try await service.generateJITConfig(
            for: .organization(login: "acme"), name: "n", runnerGroupID: 4, labels: ["a"], workFolder: "_work"
        )

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/orgs/acme/actions/runners/generate-jitconfig")
    }

    @Test("the body carries name, an integer group id, labels and work folder")
    func bodyFields() async throws {
        let (service, transport) = makeService([.json(Self.jitJSON, status: 201)])

        _ = try await service.generateJITConfig(
            for: .organization(login: "acme"), name: "vm-1a2b3c", runnerGroupID: 4,
            labels: ["self-hosted", "tart"], workFolder: "work"
        )

        let json = try body(try #require(await transport.requests.first))
        #expect(json["name"] as? String == "vm-1a2b3c")
        #expect(json["runner_group_id"] as? Int == 4)
        #expect(json["labels"] as? [String] == ["self-hosted", "tart"])
        #expect(json["work_folder"] as? String == "work")
    }

    @Test("a 422 (name or label rejected) surfaces as an HTTP status error")
    func unprocessable() async throws {
        let (service, _) = makeService([.json(#"{"message":"Validation Failed"}"#, status: 422)])

        await #expect(throws: GitHubAPIError.self) {
            _ = try await service.generateJITConfig(
                for: .repository(fullName: "o/r"), name: "n", runnerGroupID: 1, labels: ["x"], workFolder: "_work"
            )
        }
    }

    @Test("deleting a runner GitHub no longer has reports notFound, for the caller to treat as gone")
    func deleteMissingRunner() async throws {
        let (service, _) = makeService([.json("{}", status: 404)])

        await #expect(throws: GitHubAPIError.self) {
            try await service.deleteRunner(runnerId: 77, from: .repository(fullName: "o/r"))
        }
    }
}
