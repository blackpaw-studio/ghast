import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct RunnerStatsTests {
    static func runner(_ id: Int, online: Bool, busy: Bool) -> GitHubRunner {
        GitHubRunner(id: id, name: "r\(id)", os: "macOS", status: online ? "online" : "offline", busy: busy, labels: [])
    }

    static let repo = RunnerScope.repository(fullName: "octo/ghast")
    static let acme = RunnerScope.organization(login: "acme")
    static let broken = RunnerScope.organization(login: "broken")

    static let runnersByScope: [RunnerScope: [GitHubRunner]] = [
        repo: [runner(1, online: true, busy: false), runner(2, online: false, busy: false)],
        acme: [runner(3, online: true, busy: true), runner(4, online: true, busy: false)],
    ]

    @Test func sumsTotalsAcrossScopes() async throws {
        let stats = try await RunnerStats.load(scopes: [Self.repo, Self.acme]) { scope in
            Self.runnersByScope[scope] ?? []
        }

        #expect(stats == RunnerStats(total: 4, online: 3, busy: 1))
    }

    @Test func oneScopeFailingStillCountsTheOthers() async throws {
        let stats = try await RunnerStats.load(scopes: [Self.repo, Self.broken, Self.acme]) { scope in
            if scope == Self.broken { throw GitHubAPIError.httpStatus(403) }
            return Self.runnersByScope[scope] ?? []
        }

        #expect(stats == RunnerStats(total: 4, online: 3, busy: 1))
    }

    @Test func cancellationPropagates() async {
        var fetched: [RunnerScope] = []

        await #expect(throws: CancellationError.self) {
            _ = try await RunnerStats.load(scopes: [Self.repo, Self.acme]) { scope in
                fetched.append(scope)
                throw CancellationError()
            }
        }
        #expect(fetched == [Self.repo])
    }
}
